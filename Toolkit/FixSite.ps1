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
  [int]$CloseAfter = 0
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'FixSiteCore.ps1')
. (Join-Path $here 'FixSiteDevices.ps1')
if (Test-Path (Join-Path $here 'ToolkitCore.ps1')) { . (Join-Path $here 'ToolkitCore.ps1') }
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
# 2.2.0: also every user's My Drive (2.2.3: the run is on the tech's login now, so their own G: is found first)
try { if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { foreach ($u in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) { $driveRoots += (Join-Path $u.FullName 'My Drive\WireIt Sites') } } } catch {}
$opts = Merge-FsOptions $fsCfg
$opts.settings.codec = $Codec; $opts.settings.fps = $Fps; $opts.settings.resolution = $Resolution; $opts.settings.bitrate = $Bitrate
$opts.settingsAll = [bool]$AllCameras; $opts.passwordAll = [bool]$PasswordAll   # per run, never from config: a working camera is only touched when the tech ticks it this time
# 2.2.0: the site password store is vault\ (machine-wide DPAPI); 2.1's secrets\ is read once and moved
if (-not $SecretsDir) { $SecretsDir = Join-Path $here 'vault'; $script:FsLegacySecretsDir = Join-Path $here 'secrets' }
if (-not $RunsRoot) { $RunsRoot = Join-Path $here 'fixsite-runs' }
if (-not $SitesDir) { $SitesDir = Join-Path $here 'sites' }
$camResetDir = Join-Path $root 'CamReset'; $portMapDir = Join-Path $root 'PortMap'
if ($MockUrl) { $script:FsMockUrl = $MockUrl; $script:FsTestSecrets = $true }
if ($Mode -eq 'DryRun') { $script:FsTestSecrets = $true }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'; $runStart = Get-Date
$runDir = Join-Path $RunsRoot ('FixSite-' + $stamp); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'
$tempState = Join-Path (Join-Path $RunsRoot '_state') 'fixsite-temp-ips.json'; New-Item -ItemType Directory -Force -Path (Split-Path $tempState) | Out-Null
$script:FsLoginLedger = Join-Path (Split-Path $tempState) 'login-fails.json'   # 2.2.10 (Codex R19): wrong-password count per device, kept between runs (HikReset uses the same file)
# 2.2.3 (Codex #31/#33, kept without the task): a run that was killed (window closed, power lost) left its temporary PC addresses in
# this file; they are taken off FIRST, before anything else, every time Fix this site starts
if (Test-Path -LiteralPath $tempState) { try { $nr0 = Remove-FsTempIps $tempState; if ($nr0 -and -not $nr0.ok) { Write-Host ('This PC''s network from an earlier, interrupted run could not be fully put back: ' + (@($nr0.problems) -join '; ')) -ForegroundColor Yellow } } catch {} }
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
  if ($Secret) { $ss = Read-Host -AsSecureString '>'; $a = (New-Object PSCredential('x', $ss)).GetNetworkCredential().Password; Remember-Secret $a; Fs-Log 'ANSWER (hidden)'; return $a }
  $a = Read-Host '>'; Fs-Log ('ANSWER ' + $a); return $a
}
function Ask-Choice([string]$q, [string]$yes, [string]$no) {
  # 2.1.0 (Moshe, Nov 6 2026): a yes/no question is two buttons, not a typed prompt. Test runs and dry runs still use the typed answer file.
  if ($Answers -or $MockUrl -or $Mode -eq 'DryRun') { $a = Ask ($q + '  [' + $yes + ']  [' + $no + ']  (type Y or N)'); return ([string]$a).Trim() -match '^(?i)y' }
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
# 2.2.20 (Codex 2.2.19 class A, second pass): the site list is what the next visit (and Undo's "what should be here") trusts, so it
# counts as saved only when it reads back as written (Write-FsFileAtomic). 2.2.19 wrote it with a plain Set-Content under 'Continue'
# and said "Saved ..." even when the write was refused. @{ local = $true/$false; drive = $true/$false/$null (no Drive folder); why }
function Save-FsSiteListFiles([string]$json, [string]$local, [string]$drive) {
  $r = [pscustomobject]@{ local = $false; drive = $null; why = ''; driveWhy = '' }
  try { New-Item -ItemType Directory -Force -Path (Split-Path $local) -ErrorAction Stop | Out-Null; Write-FsFileAtomic $local $json; $r.local = $true } catch { $r.why = $_.Exception.Message }
  if ($drive) { try { New-Item -ItemType Directory -Force -Path (Split-Path $drive) -ErrorAction Stop | Out-Null; Write-FsFileAtomic $drive $json; $r.drive = $true } catch { $r.drive = $false; $r.driveWhy = $_.Exception.Message } }
  return $r
}
function Save-FsRunText([string]$path, [string]$text) { try { Write-FsFileAtomic $path $text; return $true } catch { Fs-Log ('not saved: ' + (Split-Path -Leaf $path) + ' - ' + $_.Exception.Message); return $false } }
function Say-PlainWarning([string]$ip) {
  # 2.2.2 (re-review H1): HTTPS that did not work (timeout, TLS, certificate) is said in red - the password was NOT sent
  $tf = Get-FsTlsFailure $ip
  if ($tf -and -not $script:PlainWarned.ContainsKey('tls|' + $ip)) { $script:PlainWarned['tls|' + $ip] = 1; Say ('    ' + $ip + ': HTTPS did not work (' + $(switch ($tf) { 'timeout' { 'no answer in time' } 'tls' { 'TLS/certificate problem' } 'unreachable' { 'not reachable' } default { 'connection problem' } }) + '), so its password was NOT sent. It is never sent over plain HTTP to a device that has HTTPS. Check the device, then press the button again.') 'Red' }
  if (-not (Test-FsSentPlain $ip) -or $script:PlainWarned.ContainsKey($ip)) { return }
  $script:PlainWarned[$ip] = 1
  Say ('    WARNING: ' + $ip + ' has no HTTPS, so its password went over plain HTTP on this network. Turn on HTTPS on it when you can.') 'Yellow'
}
function Set-Clip([string]$s) { if ($MockUrl -or $Answers) { return }; try { Set-Clipboard -Value $s } catch {} }
function Clear-Clip { if ($MockUrl -or $Answers) { return }; try { Set-Clipboard -Value ' ' } catch {} }
function Say-NetRestore($r) {
  # 2.2.1 (review H4): the tech hears it when this PC's own network could not be put back
  if (-not $r -or $r.ok) { return }
  # 2.2.10 (Moshe Nov 9): a restore that is not verified is FAILED - Run again, on screen and in the log; the journal is kept
  Say ('FAILED - Run again. THIS PC''S NETWORK IS NOT BACK TO NORMAL: ' + (@($r.problems) -join '; ') + '. The record of the change is kept: the next run puts it back first; restarting the PC also clears the temporary addresses.') 'Red'
}
# 2.2.11 (add-on #4, job receipt): at the end of a Fix / Undo run, a short plain-text receipt of what was changed and whether this
# PC's network was put back, saved on this PC (Toolkit\receipts, or the user's own folder when that one cannot be written).
function Write-FsReceipt([int]$code, $nr) {
  $res = $(switch ($code) { 0 { 'DONE' } 4 { 'DONE, but some steps did not work (see below)' } 6 { 'FAILED - Run again (this PC''s network is not back to normal)' } 2 { 'stopped before changing anything' } 9 { 'STOPPED HALF-WAY by an error (see the full log). What is listed below was done; run it again or Undo' } default { 'stopped with a problem (code ' + $code + ')' } })
  $l = @(('WireIt Toolkit ' + $script:FsVersion + ' - Fix this site receipt' + $(if ($Mode -eq 'Rollback') { ' (Undo)' } else { '' })), ('Site: ' + $(if ($siteName) { $siteName } elseif ($Site) { $Site } else { '(none)' })), ('PC: ' + $env:COMPUTERNAME + '   user: ' + $env:USERNAME + '   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), ('Result: ' + $res), '', 'Changed on the cameras / NVR:')
  $rs = @(); $rv = Get-Variable -Name results -Scope Script -ErrorAction SilentlyContinue; if ($rv) { $rs = @($rv.Value | Where-Object { $_ }) }
  if ($rs.Count) { $l += @($rs | ForEach-Object { '  - ' + ([string]$_).Replace([string][char]0x2705, '[OK]').Replace([string][char]0x274C, '[X]') }) } else { $l += '  - nothing' }
  $l += @('', 'This PC''s network:')
  $l += $(if ($nr -and -not $nr.ok) { '  NOT back to normal: ' + (@($nr.problems) -join '; ') + ' - run Restore Network' } elseif ($script:FsPcBefore -or $script:FsCoexistChanged) { '  temporary addresses taken off, adapter back as it was (checked)' } else { '  not changed' })
  if ($runDir) { $l += @('', ('Undo file and full log: ' + $runDir)) }
  $name = 'FixSite-' + $(if ($stamp) { $stamp } else { (Get-Date -Format 'yyyyMMdd-HHmmss') }) + '.txt'
  $dirs = @(); if ($env:WIREIT_RECEIPT_DIR) { $dirs += $env:WIREIT_RECEIPT_DIR } else { $dirs += (Join-Path $here 'receipts'); if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA 'WireIt\receipts') }; $dirs += (Join-Path ([IO.Path]::GetTempPath()) 'WireIt-receipts') }
  foreach ($d in $dirs) {
    try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null; $f = Join-Path $d $name; [IO.File]::WriteAllLines($f, [string[]]$l); Write-Host ('Receipt saved: ' + $f); Fs-Log ('receipt ' + $f); return $f } catch {}
  }
  return ''
}
function Done([int]$code) {
  $nr = $null; try { $nr = Remove-FsTempIps $tempState } catch { $nr = [pscustomobject]@{ ok = $false; problems = @('the clean-up stopped: ' + $_.Exception.Message) } }; Say-NetRestore $nr
  if ($nr -and -not $nr.ok) { $code = 6 }
  if ($Mode -in @('Fix', 'Rollback') -and (-not $MockUrl -or $env:WIREIT_RECEIPT_DIR)) { try { [void](Write-FsReceipt $code $nr) } catch {} }   # 2.2.11 (#4)
  # 2.2.2 (re-review H4): this PC's network not back = the run did NOT end well, whatever else worked (exit 6, the window says so)
  # 2.2.10: whatever the run's own result was (also "Stopped. Nothing was changed."), an unverified network restore ends as FAILED (6)
  if ($nr -and -not $nr.ok) { $code = 6 }
  if ($CloseAfter -gt 0) { Write-Host ''; Write-Host ('This window closes in ' + $CloseAfter + ' seconds.'); Start-Sleep -Seconds $CloseAfter }
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
trap { $tnr = $null; try { $tnr = Remove-FsTempIps $tempState } catch { $tnr = [pscustomobject]@{ ok = $false; problems = @('the clean-up stopped: ' + $_.Exception.Message) } }; try { Say-NetRestore $tnr } catch {}; if ($Mode -in @('Fix', 'Rollback') -and (-not $MockUrl -or $env:WIREIT_RECEIPT_DIR)) { try { [void](Write-FsReceipt $(if ($tnr -and -not $tnr.ok) { 6 } else { 9 }) $tnr) } catch {} }; try { Fs-Log ('stopped: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber) } catch {}; try { if ($Mode -in @('Fix', 'Rollback')) { Say ('STOPPED HALF-WAY (' + $_.Exception.Message + '). Some cameras or NVRs may already have been changed. Press Undo the last fix to put this site back, or press Fix this site again, or call the office.') 'Red' } else { Say ('Stopped unexpectedly: ' + $_.Exception.Message) 'Red' } } catch {}; exit $(if ($tnr -and -not $tnr.ok) { 6 } elseif ($Mode -in @('Fix', 'Rollback')) { 9 } else { 1 }) }   # 2.2.12 (Codex 2.2.11 #14): an honest half-way message, and the exit code the window explains   # 2.2.11 (#4): a run stopped half-way still leaves its receipt

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
  if (-not $siteFolder -and @($script:FsSiteFolderAmbiguous).Count) { Say ('"' + $Site + '" matches more than one Drive site folder (' + (@($script:FsSiteFolderAmbiguous) -join ', ') + '), so none is used. Type the full folder name.') 'Yellow' }   # 2.2.3 (Codex #40)
  $siteName = $(if ($siteFolder) { Split-Path -Leaf $siteFolder } else { $Site })
  $siteId = $(if ($Site -match '^(?i)WI-\d+$') { $Site.ToUpper() } else { '' })
  $listPath = $(if ($siteFolder) { Join-Path (Join-Path $siteFolder 'Docs') 'WireIt site list.json' } else { '' })
  $localList = Resolve-FsLocalList $SitesDir $siteName   # 2.2.3 (Codex #24)
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
$sitePwAtStart = [bool]$sec.password   # 2.2.3 (Codex #36): did this site have its password BEFORE this run made or asked one?
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
  if ($MockUrl -or $Answers -or $Mode -eq 'DryRun') { Say 'SHOWN ONCE: the site password window with the Copy button (test run - not opened).'; return }
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
  # 2.2.19 (Codex 2.2.18 class F): a progress file that cannot be saved is reported and keeps Undo incomplete (it is never "everything is back")
  $script:FsProgFail = ''
  $markDone = { param($k) $prog[$k] = (Get-Date -Format 's'); try { Write-FsFileAtomic $progF ($prog | ConvertTo-Json -Depth 3) } catch { $script:FsProgFail = $_.Exception.Message } }   # 2.2.7 (F03): written whole or not at all
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
    # 2.2.6: a run stopped mid-move has only the planned new address (ip_target): the camera is looked for there first, then on its old one
    $ipNew = $(if ($c.ip_after) { [string]$c.ip_after } elseif ($c.PSObject.Properties['ip_target'] -and $c.ip_target) { [string]$c.ip_target } else { '' })
    $ip = $(if ($ipNew -and -not $netDone) { $ipNew } else { [string]$c.ip_before }); $res = @()
    if (-not (Test-FsOnScheme $ip $pcScheme)) { [void](Add-FsTempIp (Get-FsP3 $ip) $pc $tempState) }
    $oldPw = $(if ($old.ContainsKey([string]$c.mac + '|' + [string]$c.ip_before)) { [string]$old[[string]$c.mac + '|' + [string]$c.ip_before] } else { '' })
    $mkR = ConvertTo-FsMac ([string]$c.mac); $lastPw = $(if ($mkR -and $sec.cams -and $sec.cams.ContainsKey($mkR)) { [string]$sec.cams[$mkR] } else { '' })
    $candsR = @(@($lastPw, $sec.password, $oldPw) + @($sec.known) | Where-Object { $_ } | Select-Object -Unique | Select-Object -First ([int]$opts.maxPasswordTries))   # 2.0.1: a working camera kept its own password
    $pw = ''; foreach ($cand in $candsR) { if ($cand -and (Test-FsLogin $ip $c.brand $cand) -eq 'ok') { $pw = $cand; break } }
    if (-not $pw -and -not $c.ip_after -and $ipNew -and $ip -ne [string]$c.ip_before) {
      # the interrupted move may never have taken: the camera is still on its old address
      $ip = [string]$c.ip_before; if (-not (Test-FsOnScheme $ip $pcScheme)) { [void](Add-FsTempIp (Get-FsP3 $ip) $pc $tempState) }
      foreach ($cand in $candsR) { if ($cand -and (Test-FsLogin $ip $c.brand $cand) -eq 'ok') { $pw = $cand; $ipNew = ''; break } }
    }
    # 2.2.7 (F01): a missing camera that came back and was put on its channel: the channel goes back even when the camera is gone again
    $pwLogged = [bool]$pw
    if (-not $pw -and $c.PSObject.Properties['recovered'] -and $c.recovered) { $pw = [string]$sec.password }
    if (-not $pw) { Say ('  ' + $c.name + ': cannot log in at ' + $ip + ' - not undone ' + $script:FsBad) 'Red'; $bad++; continue }
    $cr = Fs-Cred $pw
    # 2.2.15 (Codex 2.2.14 R2): a password that logs in is not proof it is THIS camera (the site password works on all of them, and
    # another camera may have taken its address since). Before ANY undo write, the device's own MAC (or serial) must match the undo
    # file. Another device, or one that does not tell: nothing is written for this camera (not its settings, password, address or
    # NVR channel) - NOT confirmed, a problem, and pressing Undo again says the same until a person sorts it out.
    # 2.2.19 (Codex 2.2.18 F01/F02/F03): the identity is read FRESH right before EACH write below (settings, password, address), not
    # once for the camera: the device answering at $ip can change while Undo works (a restart, another camera taking the address).
    $camSer = $(if ($c.PSObject.Properties['serial']) { [string]$c.serial } else { '' })
    $camIdNow = { param($at, $cred) return [string](Get-FsUndoIdentityBlock $at ([string]$c.brand) $cred ([string]$c.mac) $camSer) }
    if ($pwLogged) {
      $idWhy = & $camIdNow $ip $cr
      if ($idWhy) { Say ('  ' + $c.name + ': NOT confirmed - ' + $idWhy + '. Nothing was changed on it. Find this camera and put it back by hand ' + $script:FsBad) 'Red'; $bad++; continue }
    }
    if ($c.stream_before -and -not (& $isDone ($ck + '|settings')) -and -not ($cur = Get-FsStream $ip $c.brand $cr)) { $res += [pscustomobject]@{ text = 'settings could not be read - not put back'; ok = $false } }   # 2.2.3 (Codex #20)
    elseif ($c.stream_before -and -not (& $isDone ($ck + '|settings'))) { $want = [pscustomobject]@{ codec = $(if ([string]$c.stream_before.codec) { [string]$c.stream_before.codec } else { 'keep' }); fps = [int]$c.stream_before.fps; resolution = $(if ([int]$c.stream_before.width -gt 0 -and [int]$c.stream_before.height -gt 0) { '' + $c.stream_before.width + 'x' + $c.stream_before.height } else { 'keep' }); bitrate = [int]$c.stream_before.bitrate; gop = 0; smartCodec = 'keep' }
      # 2.2.7 (Codex file-by-file F09): EVERY setting the run found goes back - the I-frame interval (GOP) and Smart Codec too - and
      # counts as back only when the camera reads all of them back as they were (2.2.6 skipped Smart Codec and never checked GOP)
      # 2.2.19 (Codex 2.2.18 F19): a saved field the camera does not report now is NOT CHECKED (never "back"); a field the run did not
      # save (empty / 0 in the undo file) was never changed by it and is left as it is
      $extra = { param($now) $x = @()
        if ([int]$c.stream_before.gop -gt 0 -and $now) { if ([int]$now.gop -le 0) { $x += [pscustomobject]@{ field = 'gop'; from = ''; to = [int]$c.stream_before.gop; unknown = $true } } elseif ([int]$now.gop -ne [int]$c.stream_before.gop) { $x += [pscustomobject]@{ field = 'gop'; from = $now.gop; to = [int]$c.stream_before.gop; unknown = $false } } }
        $sbs = [string]$c.stream_before.smartCodec
        if ($sbs -in @('on', 'off') -and $now) { $ns = [string]$now.smartCodec; if ($ns -notin @('on', 'off')) { $x += [pscustomobject]@{ field = $(if ($sbs -eq 'on') { 'smartCodecOn' } else { 'smartCodec' }); from = ''; to = $sbs; unknown = $true } } elseif ($ns -ne $sbs) { $x += [pscustomobject]@{ field = $(if ($sbs -eq 'on') { 'smartCodecOn' } else { 'smartCodec' }); from = $ns; to = $sbs; unknown = $false } } }
        return $x }
      $diff = @(Get-FsSettingsDiff $cur $want) + @(& $extra $cur)
      $unkS = Format-FsUnknownFields $diff
      if ($unkS) { $res += [pscustomobject]@{ text = ('settings NOT CHECKED: the camera does not report its ' + $unkS + ' now, so it is not known whether they are back - nothing written'); ok = $false } }
      elseif ($diff.Count) {
        $idS = & $camIdNow $ip $cr
        if ($idS) { $res += [pscustomobject]@{ text = ('settings NOT put back: ' + $idS); ok = $false } }
        else { $w = Set-FsStream $ip $c.brand $cr $cur $diff ([string]$c.mac) $camSer 'the undo file'; $okS = [bool]$w.ok
          # 2.2.3 (Codex #20): settings count as back only when the camera reads them back as they were
          if ($okS) { $rd = Get-FsStream $ip $c.brand $cr; $okS = [bool]($rd -and -not @(Get-FsSettingsDiff $rd $want).Count -and -not @(& $extra $rd).Count) }
          $res += [pscustomobject]@{ text = 'settings back'; ok = $okS }; if ($okS) { & $markDone ($ck + '|settings') } }
      } else { & $markDone ($ck + '|settings') } }
    # An interrupted write may have taken effect before password_changed was saved. Reconcile every attempted write.
    if (($c.password_changed -or $c.password_attempted) -and $oldPw -and -not (& $isDone ($ck + '|password'))) {
      $idP = $(if ($pw -cne $oldPw) { & $camIdNow $ip $cr } else { '' })
      if ($idP) { $ok = $false; $res += [pscustomobject]@{ text = ('old password NOT put back: ' + $idP); ok = $false } }
      else {
        $ok = $(if ($pw -ceq $oldPw) { $true } else { [void](Set-FsPassword $ip $c.brand $cr $oldPw); (Test-FsLoginIs $ip $c.brand $oldPw ([string]$c.mac) $camSer) -eq 'ok' })   # 2.2.3 (Codex #20): back = the old password logs in; 2.2.20 (R12): on THIS camera (DeviceInfo + MAC)
        if ($ok) { $pw = $oldPw; $cr = Fs-Cred $pw; $mk = ConvertTo-FsMac ([string]$c.mac); if ($mk) { $sec.cams[$mk] = $oldPw }; & $markDone ($ck + '|password') }
        $res += [pscustomobject]@{ text = 'old password back'; ok = $ok }
      }
    }
    # 2.2.1 (review H8): the address goes back as it was - a camera that had DHCP gets DHCP again (also when only "set fixed" on the same address)
    $nb = $c.net_before
    $nbDhcp = $(if ($nb) { ConvertTo-FsDhcpMode $nb.dhcp } else { $null })   # 2.2.19 (Codex 2.2.18 D): dynamic / dhcp / static / manual read one way
    if ($nb -and $ipNew -and -not $netDone -and $null -eq $nbDhcp) { $res += [pscustomobject]@{ text = ('address NOT put back: the undo file does not say whether it had DHCP or a fixed address (' + [string]$nb.dhcp + ') - put it back by hand'); ok = $false } }
    elseif ($nb -and $ipNew -and -not $netDone -and ($ipNew -ne $c.ip_before -or $nbDhcp)) {
      $net = Get-FsNet $ip $c.brand $cr
      if ((Get-FsP3 ([string]$nb.ip)) -ne $pcScheme) { [void](Add-FsTempIp (Get-FsP3 ([string]$nb.ip)) $pc $tempState) }
      # 2.2.19 (Codex 2.2.18 F02): the old address must be FREE right before the move (checked live), or already hold THIS camera
      # (MAC); another device there = not moved (both would drop off the network), Undo incomplete
      $dst = $(if (-not $nbDhcp -and [string]$nb.ip -ne $ip) { Get-FsMoveTargetState ([string]$nb.ip) ([string]$c.brand) $pw ([string]$c.mac) $camSer } else { [pscustomobject]@{ state = 'free'; why = '' } })
      $idN = $(if ($net) { & $camIdNow $ip $cr } else { '' })
      if (-not $net) { $res += [pscustomobject]@{ text = 'address could not be read - not put back'; ok = $false } }
      elseif ($idN) { $res += [pscustomobject]@{ text = ('address NOT put back: ' + $idN); ok = $false } }
      elseif ($dst.state -ne 'free') { $res += [pscustomobject]@{ text = ('address NOT put back to ' + $nb.ip + ': ' + $(if ($dst.state -eq 'self') { 'this camera answers there too (two addresses?) - check it by hand' } else { $dst.why + ' - nothing was moved (both would drop off the network); free that address or move it back by hand' })); ok = $false } }
      else {
        $w = Set-FsNet $ip $c.brand $cr $net ([string]$nb.ip) ([string]$nb.mask) ([string]$nb.gw) ([string]$nb.dns1) ([string]$nb.dns2) -Dhcp:([bool]$nbDhcp)
        if ($w.ok -and $w.reboot) { [void](Restart-FsDeviceChecked $ip $c.brand $cr ([string]$c.mac) $camSer 'this camera' 'the undo file') }   # 2.2.21 (F02)
        if ($nbDhcp) {
          # 2.2.19 (Codex 2.2.18 F13): DHCP on is back only when the camera is FOUND again by its MAC and reads back DHCP on. An
          # acknowledged write, or a camera not found again, is NOT CHECKED: the step is not marked done and Undo stays incomplete.
          $dh = $(if ($w.ok) { Test-FsDhcpBack ([string]$c.mac) $camSer ([string]$c.brand) $pw ([string]$nb.ip) } else { $null })
          if ($dh -and $dh.ok) { & $markDone ($ck + '|net'); $ip = [string]$dh.ip; $res += [pscustomobject]@{ text = ('back on DHCP (found by its MAC on ' + $dh.ip + ')'); ok = $true } }
          elseif ($w.ok) { if ($dh.ip) { $ip = [string]$dh.ip }; $res += [pscustomobject]@{ text = ('DHCP sent, but NOT CHECKED: ' + $dh.why + ' - use Find cameras to find it and check it gets its address from the router'); ok = $false } }
          else { $res += [pscustomobject]@{ text = 'the camera refused DHCP - not put back'; ok = $false } }
        } else {
          $back = $w.ok -and (Wait-FsDevice ([string]$nb.ip) $c.brand $pw ([int]$opts.moveWaitSec))
          # 2.2.18 (Codex F3): answering on the old address is not proof every setting went back: read them back and compare with the saved ones
          # 2.2.19 (F02): and the device answering there must be THIS camera (MAC), read fresh
          $idB = $(if ($back) { & $camIdNow ([string]$nb.ip) (Fs-Cred $pw) } else { '' })
          $nmU = $(if ($back -and -not $idB) { Get-FsNetMismatch ([string]$nb.ip) $c.brand (Fs-Cred $pw) $net ([string]$nb.ip) ([string]$nb.mask) ([string]$nb.gw) ([string]$nb.dns1) ([string]$nb.dns2) } else { '' })
          if ($back -and $idB) { $res += [pscustomobject]@{ text = ('something answers on ' + $nb.ip + ', but NOT confirmed back: ' + $idB); ok = $false } }
          elseif ($back -and $nmU) { $ip = [string]$nb.ip; $res += [pscustomobject]@{ text = ('answers on ' + $nb.ip + ' again, but its network settings are NOT back: ' + $nmU); ok = $false } }
          elseif ($back) { & $markDone ($ck + '|net'); $ip = [string]$nb.ip; $res += [pscustomobject]@{ text = ('address back to ' + $nb.ip); ok = $true } }
          else { $res += [pscustomobject]@{ text = ('address back to ' + $nb.ip); ok = $false } }
        }
      }
    }
    # 2.2.1 (review H8): the NVR channel exactly as the backup has it; a channel this run ADDED is deleted again
    if ($c.nvr -and $c.nvr.nvr -and -not (& $isDone ($ck + '|nvr'))) {
      $nv0 = [string]$c.nvr.nvr; $nv = Resolve-FsUndoNvrIp @($r0.nvrs) $nv0 $isDone   # 2.2.2 (H8): an NVR an earlier Undo moved back answers on its old address
      if ($nv -ne $nv0) { if (-not $nvrPwR.ContainsKey($nv) -and $nvrPwR.ContainsKey($nv0)) { $nvrPwR[$nv] = $nvrPwR[$nv0] }; if (-not (Test-FsOnScheme $nv $pcScheme)) { [void](Add-FsTempIp (Get-FsP3 $nv) $pc $tempState) } }
      if (-not $nvrPwR.ContainsKey($nv)) { $res += [pscustomobject]@{ text = ('NVR ' + $nv + ': no saved login - put ch ' + $c.nvr.channel + ' back by hand'); ok = $false } }
      else {
        # 2.2.18 (Codex F2): what this run wrote on the channel = one of this camera's addresses; where Undo checked its MAC just now
        $chOwn = @($ip, [string]$c.ip_before, [string]$c.ip_after, [string]$(if ($c.PSObject.Properties['ip_target']) { $c.ip_target } else { '' })) | Where-Object { $_ }
        $chVer = $(if ($pwLogged) { $ip } else { '' }); $chSer = $(if ($c.PSObject.Properties['serial']) { [string]$c.serial } else { '' })
        $ncr = Fs-Cred $nvrPwR[$nv]; $bfile = $(if ($c.nvr.PSObject.Properties['before_file'] -and [string]$c.nvr.before_file) { Join-Path $RollbackDir (([string]$c.nvr.before_file) -replace '[\\/]', [string][IO.Path]::DirectorySeparatorChar) } else { '' })
        if ([string]$c.nvr.action -eq 'refused') { $ok = $true; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ': not changed by the run (it showed another live camera)'); ok = $true } }   # 2.2.10 (Codex R06)
        elseif ([string]($idw = Get-FsUndoNvrBlock $nv $ncr $c.nvr 'nvr_mac' 'nvr_serial')) { $ok = $false; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' NOT put back: ' + $idw + '. Nothing was written to it - check which NVR is there and put the channel back by hand'); ok = $false } }   # 2.2.16 (Codex 2.2.15 F3)
        elseif ([string]$c.nvr.action -eq 'pending' -and -not ($bfile -and (Test-Path -LiteralPath $bfile))) {
          # 2.2.7 (F01): the run stopped while it changed this channel and no saved copy exists = the channel did not exist before
          # (it was being ADDED). Removed again only when it is there and points at this camera; otherwise nothing was changed.
          # 2.2.18 (Codex F2): read with Get-FsUndoChannelOwner (one channel, fresh): a channel that could NOT be read is no longer
          # "was never added" (2.2.17 read a failed list as no channel), and an address this camera had is checked for its MAC
          $ow = Get-FsUndoChannelOwner $nv $ncr ([int]$c.nvr.channel) @($chOwn) @() $chVer ([string]$c.brand) $pw ([string]$c.mac) $chSer
          if ($ow.state -eq 'mine') { $ok = Remove-FsNvrChannel $nv $ncr ([int]$c.nvr.channel); if ($ok) { $ok = ((Get-FsUndoChannelOwner $nv $ncr ([int]$c.nvr.channel) @($chOwn)).state -eq 'gone') }; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' that the stopped run was adding: ' + $(if ($ok) { 'removed (the NVR no longer has it)' } else { 'NOT confirmed removed - check ch ' + $c.nvr.channel + ' in the NVR' })); ok = $ok } }
          elseif ($ow.state -eq 'other') { $ok = $true; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ': not changed by the stopped run'); ok = $true } }
          elseif ($ow.state -eq 'gone') { $ok = $true; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ': was never added'); ok = $true } }
          else { $ok = $false; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' NOT checked: ' + $ow.why + '. Nothing was written - press Undo again'); ok = $false } }
        }
        elseif ([string]$c.nvr.action -eq 'added') {
          # 2.2.18 (Codex F2): a channel this run ADDED is deleted again ONLY while it still shows this camera. Another camera on it now
          # (someone set it up since), or a channel that cannot be read = left alone, NOT undone, Undo incomplete. Gone already = back.
          $ow = Get-FsUndoChannelOwner $nv $ncr ([int]$c.nvr.channel) @($chOwn) @() $chVer ([string]$c.brand) $pw ([string]$c.mac) $chSer
          if ($ow.state -eq 'gone') { $ok = $true; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' that the run added: already gone'); ok = $true } }
          elseif ($ow.state -ne 'mine') { $ok = $false; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' that the run added NOT removed: ' + $ow.why + '. Nothing was written to it (that camera keeps recording) - check ch ' + $c.nvr.channel + ' in the NVR by hand'); ok = $false } }
          else {
            $ok = Remove-FsNvrChannel $nv $ncr ([int]$c.nvr.channel)
            if ($ok) { $ok = ((Get-FsUndoChannelOwner $nv $ncr ([int]$c.nvr.channel) @($chOwn)).state -eq 'gone') }   # 2.2.18: an accepted DELETE counts once the NVR reads no such channel
            $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' that the run added: ' + $(if ($ok) { 'removed' } else { 'NOT confirmed removed - check ch ' + $c.nvr.channel + ' in the NVR' })); ok = $ok }
          }
        }
        elseif ($bfile -and (Test-Path -LiteralPath $bfile)) {
          # 2.2.14 (Codex 2.2.13 F8): back = video on it again from the camera the saved copy names; a DIFFERENT original camera never
          # gets this camera's password (only one that logs in to it), otherwise its password is NOT confirmed (by hand).
          # Restore-FsUndoChannel writes the saved copy with Restore-FsNvrChannel, then checks the video.
          $origC = @(@($sec.password) + @($sec.known) + @($old.Keys | Where-Object { $_ -like ('*|' + (Get-FsChannelXmlIp ([IO.File]::ReadAllText($bfile)))) } | ForEach-Object { $old[$_] }) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique | Select-Object -First ([int]$opts.maxPasswordTries))
          $own = @($ip, [string]$c.ip_before, [string]$c.ip_after, [string]$(if ($c.PSObject.Properties['ip_target']) { $c.ip_target } else { '' })) | Where-Object { $_ }
          # 2.2.18 (Codex F2): the saved copy goes back ONLY while the channel still shows this camera (what this run wrote) or already the
          # camera the saved copy names (an earlier Undo). Another camera on it now = left alone (it keeps recording), Undo incomplete.
          $ow = Get-FsUndoChannelOwner $nv $ncr ([int]$c.nvr.channel) @($own) @(Get-FsChannelXmlIp ([IO.File]::ReadAllText($bfile))) $chVer ([string]$c.brand) $pw ([string]$c.mac) $chSer
          if ($ow.state -eq 'saved') {
            # 2.2.19 (Codex 2.2.18 F01): the channel already shows the camera its saved copy names (an earlier Undo, or the run never got
            # to it): nothing is written (that camera's identity is not known here); back only with video on it from that address
            $vidS = Test-FsVideo $nv $ncr ([int]$c.nvr.channel) ([string]$ow.ip) ([string]$c.brand) $null
            $ok = [bool]$vidS; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' already shows ' + $ow.ip + ' as the saved copy has it - nothing written; ' + $(if ($vidS) { 'video on it' } else { 'NO video on it - NOT confirmed, check ch ' + $c.nvr.channel + ' in the NVR' })); ok = $ok }
          }
          elseif ($ow.state -ne 'mine') { $ok = $false; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' NOT put back: ' + $(if ($ow.state -eq 'gone') { 'the NVR no longer has that channel' } else { $ow.why }) + '. Nothing was written to it - check ch ' + $c.nvr.channel + ' in the NVR by hand'); ok = $false } }
          else {
            $w = Restore-FsUndoChannel $nv $ncr ([int]$c.nvr.channel) ([IO.File]::ReadAllText($bfile)) @($own) $pw $c.brand @($origC) $(if ($MockUrl) { 6 } else { 90 })
            $ok = [bool]$w.ok; $res += [pscustomobject]@{ text = [string]$w.text; ok = $ok }
          }
        }
        else {
          # 2.2.18 (Codex F2): no saved copy: the channel is pointed back at the camera's old address only while it still shows this camera
          $ow = Get-FsUndoChannelOwner $nv $ncr ([int]$c.nvr.channel) @($chOwn) @() $chVer ([string]$c.brand) $pw ([string]$c.mac) $chSer
          if ($ow.state -ne 'mine') { $ok = $false; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' NOT put back: ' + $(if ($ow.state -eq 'gone') { 'the NVR no longer has that channel' } else { $ow.why }) + '. Nothing was written to it - check ch ' + $c.nvr.channel + ' in the NVR by hand'); ok = $false } }
          else {
            $w = Set-FsNvrChannel $nv $ncr ([int]$c.nvr.channel) ([string]$c.ip_before) $pw $c.brand '' @([string]$c.ip_after, [string]$(if ($c.PSObject.Properties['ip_target']) { $c.ip_target } else { '' })); $ok = [bool]$w.ok   # 2.2.10 (Codex R06): the camera's own addresses may be moved off
            # 2.2.18 (Codex F3 twin): an accepted channel write is not proof: back = the NVR reads ch N back pointing at the old address
            $rbk = $null; if ($ok) { $rbk = Get-FsUndoChannelOwner $nv $ncr ([int]$c.nvr.channel) @([string]$c.ip_before) -ReadBack; $ok = ($rbk.state -eq 'mine') }
            $res += [pscustomobject]@{ text = $(if ($w.why) { [string]$w.why } elseif ($rbk -and -not $ok) { 'NVR ch ' + $c.nvr.channel + ': the NVR accepted ' + $c.ip_before + ', but reads back ' + $(if ($rbk.ip) { $rbk.ip } else { $rbk.why }) + ' - NOT back, check ch ' + $c.nvr.channel + ' in the NVR' } else { 'NVR ch ' + $c.nvr.channel + ' back to ' + $c.ip_before + ' (no saved copy of the channel)' }); ok = $ok }
          }
        }
        Say-PlainWarning $nv
        if ($ok) { & $markDone ($ck + '|nvr') }
      }
    }
    if (-not $res.Count) { Say ('  ' + $c.name + ': already put back by an earlier undo ' + $script:FsOk); continue }
    $line = Format-FsCheckLine $c.name $res; if ($line -like ('*' + $script:FsBad + '*')) { $bad++ }; Say ('  ' + $line)
  }
  # 2.0.3: NVR passwords back (before the NVR moves back, at the address the change was made on)
  foreach ($np in @($r0.nvr_passwords | Where-Object { $_ -and ($_.changed -or $_.attempted) })) {
    $nip0 = [string]$np.ip; if (& $isDone ('nvrpw|' + $nip0)) { continue }
    $oldN = $(if ($old.ContainsKey('nvr|' + $nip0)) { [string]$old['nvr|' + $nip0] } else { '' })
    $nip = Resolve-FsUndoNvrIp @($r0.nvrs) $nip0 $isDone   # 2.2.2 (H8): moved back by an earlier Undo -> its old address
    if ($nip -ne $nip0) { if (-not $nvrPwR.ContainsKey($nip) -and $nvrPwR.ContainsKey($nip0)) { $nvrPwR[$nip] = $nvrPwR[$nip0] }; if (-not (Test-FsOnScheme $nip $pcScheme)) { [void](Add-FsTempIp (Get-FsP3 $nip) $pc $tempState) } }
    if (-not $oldN) { Say ('  NVR ' + $nip + ': its old password is not on this PC - not undone ' + $script:FsBad) 'Red'; $bad++; continue }
    # The saved current login may still be the old one if the write was interrupted before verification. Resolve it first.
    $ncands = @(@($nvrPwR[$nip], $sec.password, $oldN) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ label = 'saved at this site'; value = [string]$_ } })
    $working = Find-FsPassword $nip 'Hikvision' $ncands ([int]$opts.maxPasswordTries)
    $ok = $false
    # 2.2.16 (Codex 2.2.15 F3): a password that logs in is not proof it is the same NVR: its MAC / serial must match the undo file first
    $idw = $(if ($working.state -eq 'ok') { Get-FsUndoNvrBlock $nip (Fs-Cred $working.value) $np } else { '' })
    if ($idw) { Say ('  NVR ' + $nip + ': old password NOT put back - ' + $idw + '. Nothing was written to it; check which NVR is there and do it by hand ' + $script:FsBad) 'Red'; $bad++; continue }
    if ($working.state -eq 'ok') {
      $ok = ($working.value -ceq $oldN)
      if (-not $ok) {
        [void](Set-FsPassword $nip 'Hikvision' (Fs-Cred $working.value) $oldN); Say-PlainWarning $nip
        $ok = ((Test-FsLoginIs $nip 'Hikvision' $oldN ([string](Get-FsProp $np 'mac' '')) ([string](Get-FsProp $np 'serial' '')) 'that NVR') -eq 'ok')   # back = the old password logs in; 2.2.20 (R12): on THAT NVR
      }
    }
    if ($ok) { $nvrPwR[$nip] = $oldN; $sec.nvr[$nip] = $oldN; if ($nip -ne $nip0) { $nvrPwR[$nip0] = $oldN; $sec.nvr[$nip0] = $oldN }; & $markDone ('nvrpw|' + $nip0) } else { $bad++ }
    Say ('  NVR ' + $nip + ': old password back ' + $(if ($ok) { $script:FsOk } else { $script:FsBad }))
  }
  foreach ($n in @($r0.nvrs)) {
    if (& $isDone ('nvrmove|' + [string]$n.ip)) { continue }
    # 2.2.7 (F02): a run stopped mid-move (older undo files): the login saved under its old address is the one it has
    if (-not $nvrPwR.ContainsKey([string]$n.target) -and $nvrPwR.ContainsKey([string]$n.ip)) { $nvrPwR[[string]$n.target] = $nvrPwR[[string]$n.ip] }
    if (-not $nvrPwR.ContainsKey([string]$n.target)) { Say ('  NVR ' + $n.target + ': no saved login - move it back by hand to ' + $n.old.ip) 'Yellow'; $bad++; continue }
    $oldDhcp = ConvertTo-FsDhcpMode $n.old.dhcp   # 2.2.19 (Codex 2.2.18 D)
    if ($null -eq $oldDhcp) { Say ('  NVR ' + $n.target + ': NOT moved back - the undo file does not say whether it had DHCP or a fixed address (' + [string]$n.old.dhcp + '); move it back by hand to ' + $n.old.ip + ' ' + $script:FsBad) 'Red'; $bad++; continue }
    $npw = $nvrPwR[[string]$n.target]; $nser = $(if ($n.PSObject.Properties['serial']) { [string]$n.serial } else { '' })
    $cr = Fs-Cred $npw; $net = Get-FsNet ([string]$n.target) 'Hikvision' $cr; [void](Add-FsTempIp (Get-FsP3 ([string]$n.old.ip)) $pc $tempState)
    if (-not $net -and [string]$n.target -ne [string]$n.old.ip -and (Test-FsLogin ([string]$n.old.ip) 'Hikvision' $npw) -eq 'ok') {
      # 2.2.7 (F02): the stopped run's move never took: the NVR still answers on its old address
      # 2.2.16 (Codex 2.2.15 F3): only when the device there IS that NVR (MAC / serial); another NVR there = not confirmed
      $idw = Get-FsUndoNvrBlock ([string]$n.old.ip) $cr $n
      if ($idw) { Say ('  NVR ' + $n.old.ip + ': NOT confirmed back - ' + $idw + '. Nothing was written; check which NVR is there and move it back by hand ' + $script:FsBad) 'Red'; $bad++; continue }
      # 2.2.19 (Codex 2.2.18 C): "still there" counts only when its saved settings read back as they were (address, mask, router, DNS, fixed / DHCP)
      $nm0 = Get-FsNetMismatch ([string]$n.old.ip) 'Hikvision' $cr $null ([string]$n.old.ip) ([string]$n.old.mask) ([string]$n.old.gw) ([string]$n.old.dns1) ([string]$n.old.dns2) -Dhcp:([bool]$oldDhcp)
      if ($nm0) { Say ('  NVR: still on ' + $n.old.ip + ' (the move never took), but its network settings are NOT as saved: ' + $nm0 + ' ' + $script:FsBad) 'Red'; $bad++; continue }
      & $markDone ('nvrmove|' + [string]$n.ip); Say ('  NVR: still on ' + $n.old.ip + ' (the move never took) ' + $script:FsOk); continue
    }
    if (-not $net) { Say ('  NVR ' + $n.target + ': its address settings could not be read - not moved back ' + $script:FsBad) 'Red'; $bad++; continue }
    # 2.2.16 (Codex 2.2.15 F3): the device at the moved-to address must be THAT NVR (MAC / serial in the undo file) before its address is
    # written; another NVR there, an unreadable identity, or an older undo file without one = nothing written, NOT confirmed
    $idw = Get-FsUndoNvrBlock ([string]$n.target) $cr $n
    if ($idw) { Say ('  NVR ' + $n.target + ': NOT moved back to ' + $n.old.ip + ' - ' + $idw + '. Nothing was written to it; check which NVR is there and move it back by hand ' + $script:FsBad) 'Red'; $bad++; continue }
    # 2.2.19 (Codex 2.2.18 F02): the old address must be FREE right before the move (checked live); another device there = not moved
    if (-not $oldDhcp -and [string]$n.old.ip -ne [string]$n.target) {
      $dst = Get-FsMoveTargetState ([string]$n.old.ip) 'Hikvision' $npw ([string]$n.mac) $nser 'that NVR'
      if ($dst.state -ne 'free') { Say ('  NVR ' + $n.target + ': NOT moved back to ' + $n.old.ip + ' - ' + $(if ($dst.state -eq 'self') { 'that NVR answers there too (two addresses?)' } else { $dst.why }) + '. Nothing was moved (both would drop off the network); free that address or move it back by hand ' + $script:FsBad) 'Red'; $bad++; continue }
    }
    $w = Set-FsNet ([string]$n.target) 'Hikvision' $cr $net ([string]$n.old.ip) ([string]$n.old.mask) ([string]$n.old.gw) ([string]$n.old.dns1) ([string]$n.old.dns2) -Dhcp:([bool]$oldDhcp)
    if ($w.ok -and $w.reboot) { [void](Restart-FsDeviceChecked ([string]$n.target) 'Hikvision' $cr ([string]$n.mac) $nser 'that NVR' 'the undo file') }   # 2.2.21 (F02)
    $nmN = ''; $backN = $false; $where = [string]$n.old.ip
    if ($oldDhcp) {
      # 2.2.19 (Codex 2.2.18 F13): DHCP on is back only when the NVR is FOUND again by its MAC and reads back DHCP on; an acknowledged
      # write alone is NOT CHECKED (the step is not marked done, Undo stays incomplete)
      if ($w.ok) { $dh = Test-FsDhcpBack ([string]$n.mac) $nser 'Hikvision' $npw ([string]$n.target) 'that NVR'; $backN = [bool]$dh.ok; if ($dh.ip) { $where = [string]$dh.ip }; if (-not $backN) { $nmN = $dh.why } }
    } else {
      # 2.2.3 (Codex #20): done only when the NVR answers on its old address (after the restart it may need)
      $backN = $w.ok -and (Wait-FsDevice ([string]$n.old.ip) 'Hikvision' $npw ([int]$opts.rebootWaitSec))
      # 2.2.19 (F02/F03): the recorder answering there must be THAT NVR (fresh MAC / serial)
      if ($backN) { $idB = Get-FsUndoNvrBlock ([string]$n.old.ip) (Fs-Cred $npw) $n; if ($idB) { $backN = $false; $nmN = 'something answers there, but ' + $idB } }
      # 2.2.18 (Codex F3): answering on the old address is not proof: every saved setting (mask, router, DNS, fixed / DHCP) must read back
      if ($backN) { $nmN = Get-FsNetMismatch ([string]$n.old.ip) 'Hikvision' (Fs-Cred $npw) $net ([string]$n.old.ip) ([string]$n.old.mask) ([string]$n.old.gw) ([string]$n.old.dns1) ([string]$n.old.dns2); if ($nmN) { $backN = $false; $nmN = 'it answers there, but its network settings are NOT back: ' + $nmN } }
    }
    if ($backN) { & $markDone ('nvrmove|' + [string]$n.ip) } else { $bad++ }
    Say ('  NVR: back to ' + $(if ($oldDhcp) { 'DHCP' + $(if ($backN) { ' (found by its MAC on ' + $where + ')' } else { '' }) } else { $n.old.ip }) + $(if ($oldDhcp -and $w.ok -and -not $backN) { ' - sent, but NOT CHECKED: ' + $nmN + ' - use Find cameras to find it and check it' } elseif ($nmN) { ' - ' + $nmN } elseif ($w.ok -and -not $backN) { ' - accepted, but it does not answer there' } elseif (-not $w.ok) { ' - the NVR refused the settings' } else { '' }) + ' ' + $(if ($backN) { $script:FsOk } else { $script:FsBad }))
  }
  Say-NetRestore (Remove-FsTempIps $tempState)
  try { Save-FsSecrets $SecretsDir $sec } catch { Say ('  The site''s saved passwords could not be updated on this PC (' + $_.Exception.Message + ') - the old passwords that went back are not saved here ' + $script:FsBad) 'Red'; $bad++ }   # 2.2.19 (class F)
  if ($script:FsProgFail) { Say ('  Undo''s progress file could not be saved (' + $script:FsProgFail + '), so pressing Undo again would not know what already went back ' + $script:FsBad) 'Red'; $bad++ }
  # 2.2.20 (class A): the "undone" mark is written whole and read back; one that cannot be saved is said (Undo itself already ran)
  if (-not $bad) { if (-not (Save-FsRunText (Join-Path $RollbackDir 'undone.txt') (Get-Date -Format 's'))) { Say 'Undo finished, but the "undone" mark could not be saved in the run folder: the window may still offer Undo for this run.' 'Yellow' } }
  elseif (-not (Save-FsRunText (Join-Path $RollbackDir 'undo-incomplete.txt') ((Get-Date -Format 's') + ' ' + $bad + ' problem(s); Undo can be pressed again'))) { Say 'The "undo incomplete" mark could not be saved in the run folder.' 'Yellow' }
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
  if ($k) { [void](Save-FsRunText (Join-Path $runDir 'site.txt') $script:siteName) }   # 2.2.20 (class A): written whole and read back   # the window fills the site box with it (a new name only once it is saved: Save-NewSite)
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
      # 2.2.3 (Codex #8/#9): only the picked network is scanned, and only THIS run's scan is used: the old out\latest.json (another
      # site's, maybe) is moved aside first, and a failed finder (exit code, or no new file) gives no devices instead of stale ones
      # 2.2.20 (Codex 2.2.19 class D sweep): "this run's scan" is proven by the old file being GONE before the finder runs, not only by a
      # time tolerance: when the old out\latest.json cannot be moved aside (or is still there), no scan result is used this run
      $lj = Join-Path $camResetDir 'out\latest.json'; $ljAside = $true
      if (Test-Path -LiteralPath $lj) { try { Move-Item -LiteralPath $lj -Destination ($lj + '.prev') -Force -ErrorAction Stop } catch { Fs-Log ('the previous scan result could not be moved aside: ' + $_.Exception.Message) }; if (Test-Path -LiteralPath $lj) { $ljAside = $false } }
      # 2.2.20 (Codex 2.2.19 class D, second pass): the finder gets a new run id and echoes it in latest.json; only a result carrying it is used
      $fcRun = [guid]::NewGuid().ToString('N')
      $fcExit = 0; if ($ljAside) { $null = & $psexe -NoProfile -ExecutionPolicy Bypass -File $fc -NoLogin -LocalIp ([string]$pc.ip) -RunId $fcRun 2>&1; $fcExit = $LASTEXITCODE }
      $fcRead = $(if ($ljAside) { Read-FsScanForRun $lj $fcExit $fcRun } else { [pscustomobject]@{ ok = $false; why = 'the old result is still there'; scan = $null } })
      $scanOk = $ljAside -and $fcRead.ok -and (Test-FsFreshScan $lj $fcExit $runStart)
      if (-not $ljAside) { Say 'The previous Find cameras result (out\latest.json) could not be moved aside, so no scan result is used this run (only the NVR and the site list) - it could be another site''s.' 'Yellow' }
      elseif (-not $scanOk) { Say ('Find cameras did not finish a scan on this network' + $(if ($fcRead.why) { ' (' + $fcRead.why + ')' } elseif ($fcExit) { ' (code ' + $fcExit + ')' } else { '' }) + ', so its results are not used (only the NVR and the site list).') 'Yellow' }
      $fcDevs = @(); if ($scanOk) { $fcDevs = @(foreach ($sd in @($fcRead.scan.devices)) { if ($null -eq $sd) { continue }; $kd = ''; $kp = $sd.PSObject.Properties['Kind']; if ($kp -and $kp.Value) { $kd = [string]$kp.Value }; $x = ConvertTo-TkScanDevice $sd $kd; if ($x) { $x } }) }   # the same conversion as Get-TkScanDevices, on the object read once
      foreach ($d in $fcDevs) { $found += [pscustomobject]@{ brand = $d.brand; model = $d.model; serial = $d.serial; mac = $d.mac; ip = $d.ip; firmware = $d.firmware; kind = $(if ($d.kind -eq 'recorder') { 'nvr' } else { $d.kind }); activated = $true } }
      if ($scanOk) { foreach ($d in @($fcRead.scan.devices)) { if ($d -and [string]$d.Activated -match '(?i)false|no') { foreach ($f in $found) { if ($f.ip -eq $d.IP) { $f.activated = $false } } } } }
    } else { Say 'Find cameras is not on this PC (C:\WireIt\CamReset), so only the NVR''s list and the site list are used.' 'Yellow' }
    foreach ($d in @(Find-FsDahua)) { if (-not @($found | Where-Object { $_.ip -eq $d.ip }).Count) { $found += $d } }
  }
  if ($NewSite) { Resolve-NewSite $found $pc.gw }
  # list addresses nobody answered for: try them too (a camera can miss the discovery)
  # 2.2.6 (Codex file-by-file C): a device answering at a saved camera's address is NOT that camera until it says so itself: it gets no
  # MAC or serial from the list (another camera may have the address now). Its own MAC/serial is read after it logs in (step 4).
  foreach ($c in @($(if ($list) { $list.cameras } else { @() }))) { $lip = [string]$c.ip; if ($lip -and -not @($found | Where-Object { $_.ip -eq $lip }).Count -and (Get-FsP3 $lip) -eq $scheme) { $s = Test-FsLogin $lip (Get-FsBrand ([string]$c.brand) ([string]$c.model)) ''; if ($s -ne 'noanswer') { $found += [pscustomobject]@{ brand = (Get-FsBrand ([string]$c.brand) ([string]$c.model)); model = [string]$c.model; serial = ''; mac = ''; listMac = [string]$c.mac; ip = $lip; kind = 'camera'; activated = $true } } } }
  $found = @($found | Where-Object { $_.ip -and $_.ip -ne $pc.ip -and $_.ip -ne $pc.gw -and ($_.kind -in @('camera', 'nvr')) })
  $found = @(Select-FsFoundOnNet $found $pc $pcAll)   # 2.2.3 (Codex #8): devices on the PC's OTHER network are not this site's
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
    $fd0 = @($found | Where-Object { $_.ip -eq $nip })[0]; $b0 = $(if ($fd0) { Get-FsBrand $fd0.brand $fd0.model } else { 'Hikvision' })
    if (-not (Test-FsBrandSupported $b0 'nvr')) { Say ('NVR ' + $nip + ' is a ' + $b0 + ': Fix this site does not support it, so no password is tried and nothing on it is changed.') 'Yellow'; $observed.nvrs += [pscustomobject]([ordered]@{ ip = $nip; net = $null; brand = $b0; model = [string]$fd0.model; mac = [string]$fd0.mac; login = 'not supported'; channels = @() }); continue }   # 2.2.3 (Codex #28)
    $cands = @(); if ($sec.nvr -and $sec.nvr.ContainsKey($nip)) { $cands += [pscustomobject]@{ label = 'saved NVR password'; value = [string]$sec.nvr[$nip] } }
    $cands += @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries - 1) '' (Get-NewSiteDefaults 'Hikvision'))
    $fp = Find-FsPassword $nip 'Hikvision' $cands ([int]$opts.maxPasswordTries - 1)
    if ($fp.state -ne 'ok' -and $fp.state -ne 'noanswer' -and $fp.state -ne 'locked') {
      $typed = Ask ('Type the password of the NVR at ' + $nip + ' (hidden; Enter = skip - then cameras cannot be put back on it):') -Secret
      if ($typed) { Remember-Secret $typed; if ((Test-FsLogin $nip 'Hikvision' $typed) -eq 'ok') { $fp = [pscustomobject]@{ state = 'ok'; label = 'typed'; value = $typed } } else { Say 'That NVR password did not work (not tried again, so it does not lock).' 'Yellow' } }
    }
    $nobj = [ordered]@{ ip = $nip; net = $null; brand = 'Hikvision'; model = ''; mac = ''; login = $(if ($fp.state -eq 'ok') { $fp.label } elseif ($fp.state -eq 'locked') { 'locked' } else { 'unknown' }); channels = @(); channelsRead = $false }
    $fd = @($found | Where-Object { $_.ip -eq $nip })[0]; if ($fd) { $nobj.model = $fd.model; $nobj.mac = $fd.mac; $nobj.brand = (Get-FsBrand $fd.brand $fd.model) }
    if ($fp.state -eq 'ok') {
      $nvrPw[$nip] = $fp.value; $sec.nvr[$nip] = $fp.value
      $ntN = Get-FsNet $nip 'Hikvision' (Fs-Cred $fp.value); if ($ntN) { $nobj.net = [ordered]@{ dhcp = [bool]$ntN.dhcp; gw = [string]$ntN.gw; mask = [string]$ntN.mask; dns1 = [string]$ntN.dns1 } }   # 2.2.3 (Codex #30)
      # 2.2.15 (Codex 2.2.14 R1): a channel list that could not be read is NOT "no channels": the scan keeps that it is unknown
      # (channelsRead), so no camera this NVR may record gets a new password, a new address or the official reset in this run
      $rdl = Read-FsNvrChannelList $nip (Fs-Cred $fp.value); $chs = @($rdl.channels); $nobj.channelsRead = [bool]$rdl.ok
      $nobj.channels = @($chs | ForEach-Object { [ordered]@{ channel = $_.channel; ip = $_.ip; online = $_.online; name = $_.name; protocol = $_.protocol } })
      if ($rdl.ok) { Say ('NVR ' + $nip + ': ' + $chs.Count + ' camera channel(s), ' + @($chs | Where-Object { $_.online -eq $false }).Count + ' without video.') }
      else { Say ('NVR ' + $nip + ': its camera channel list could NOT be read (' + $rdl.why + '). Cameras it may record keep their password and address in this run.') 'Yellow' }
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
  # 2.2.6: a device found only at a saved camera's address may try that camera's saved password (a try, not its identity)
    $fp = Find-FsPassword $d.ip $o.brand @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries - 1) $(if ($o.mac) { $o.mac } else { [string](Get-FsProp $d 'listMac' '') }) (Get-NewSiteDefaults $o.brand)) ([int]$opts.maxPasswordTries - 1)
    if ($fp.state -eq 'noanswer') { $o.answers = $false; $o.login = '' }
    elseif ($fp.state -eq 'ok') {
      $o.login = $fp.label; $pwFor[$d.ip] = $fp.value; $cr = Fs-Cred $fp.value
      if ([string](Get-FsProp $d 'listMac' '') -and (-not $o.mac -or -not $o.serial)) { $inf = $null; try { $inf = Get-FsInfo $d.ip $o.brand $cr } catch {}; if ($inf) { if (-not $o.mac -and $inf.PSObject.Properties['mac'] -and $inf.mac) { $o.mac = [string]$inf.mac }; if (-not $o.serial -and $inf.serial) { $o.serial = [string]$inf.serial }; if (-not $o.model -and $inf.model) { $o.model = [string]$inf.model } } }   # 2.2.6: its own identity, before anything is saved under it
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
  # no passwords in it: logins are labels only. 2.2.20 (Codex 2.2.19 class A, second pass): this run's record of what it found is written
  # whole and read back; in Fix mode a record that cannot be saved stops the run HERE, before any device is changed (exit 7)
  if (-not (Save-FsRunText (Join-Path $runDir 'scan.json') ([string]($observed | ConvertTo-Json -Depth 8)))) {
    if ($Mode -eq 'Fix') { Say ('STOPPED: this run''s scan record (' + (Join-Path $runDir 'scan.json') + ') could not be saved. Nothing was changed. Make the runs folder writable (or free some disk space), then run again.') 'Red'; Done 7 }
    Say ('(this run''s scan record could not be saved in ' + $runDir + ')') 'Yellow'
  }
}

# =====================================================================================
#  PLAN
# =====================================================================================
$opts.newSite = [bool]$NewSite
$opts.factoryToSite = [bool]($NewSite -or -not $sitePwAtStart -or $sitePwPending)   # 2.0.3: no site password yet = devices on a factory password get it; 2.2.3 (Codex #36): decided from the start of the run, not after this run made one
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
# 2.2.20 (Codex 2.2.19 class A, second pass): the plan (what the YES approves) is written whole and read back; in Fix mode a plan that
# cannot be saved stops the run before the YES and before any device change (exit 7)
if (-not (Save-FsRunText (Join-Path $runDir 'plan.json') ([string]($plan | ConvertTo-Json -Depth 8)))) {
  if ($Mode -eq 'Fix') { Say ('STOPPED: this run''s plan (' + (Join-Path $runDir 'plan.json') + ') could not be saved. Nothing was changed. Make the runs folder writable (or free some disk space), then run again.') 'Red'; Done 7 }
  Say ('(this run''s plan could not be saved in ' + $runDir + ')') 'Yellow'
}
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
  $json = [string]($nl | ConvertTo-Json -Depth 6)
  $sv = Save-FsSiteListFiles $json $localList $listPath
  if ($sv.drive -eq $false) { Say ('Could not write the list to Drive (' + $sv.driveWhy + ').' + $(if ($sv.local) { ' It is saved on this PC.' } else { '' })) 'Yellow' }
  $secOk = $true; try { Save-FsSecrets $SecretsDir $sec } catch { $secOk = $false; Say ('The site''s secret store was NOT saved (' + $_.Exception.Message + '): the site password is not remembered on this PC. Write it down now (Bitwarden).') 'Red' }
  if (-not (Save-FsRunText (Join-Path $runDir 'site.txt') $siteName)) { Say 'The window could not be told the new site''s name: type it in the site box next time.' 'Yellow' }
  if ($sv.local) { Say ('Saved this site as "' + $siteName + '" on this PC: ' + @($nl.cameras).Count + ' camera(s), no passwords. Next time pick it in the site box, or press New site again - it recognises the NVR.') 'Green' }
  else { Say ('This site was NOT saved on this PC (' + $sv.why + '): the next visit will not know what should be here.' + $(if ($sv.drive) { ' (The copy in the site''s Drive folder was saved.)' } else { '' })) 'Red' }
}
function Offer-List {
  if ($NewSite) { if ($Mode -eq 'DryRun') { Say ('(dry run) At the end it would save this site as "' + $siteName + '" on this PC.') } else { Save-NewSite }; return }
  if ($Mode -eq 'DryRun') { if (-not $list) { Say '(dry run) At the end it would offer: "Save this as the site''s list?"' }; return }
  $newOnes = @($plan.cams | Where-Object { -not $_.onList -and $_.state -ne 'missing' })
  if ($list -and -not $newOnes.Count -and $listFrom -notlike '*snapshot*') { return }
  $q = $(if (-not $list -or $listFrom -like '*snapshot*') { 'Save this as the site''s list (' + @($plan.cams).Count + ' cameras, no passwords)? Then next time it knows what should be here. Type Y to save.' } else { 'Add the ' + $newOnes.Count + ' camera(s) that are not on the site list to it? Type Y to add.' })
  if ((Ask $q) -notmatch '^(?i)y') { return }
  $nl = New-FsSiteList $siteName $siteId $plan $observed
  if ($list -and $listFrom -notlike '*snapshot*') { $nl.cameras = @(Merge-FsSiteListCams @($list.cameras) @($nl.cameras)) }   # 2.2.3 (Codex #38)
  $json = [string]($nl | ConvertTo-Json -Depth 6)
  $sv = Save-FsSiteListFiles $json $localList $listPath   # 2.2.20 (class A): "Saved" only when the file reads back as written
  if (-not $sv.local) { Say ('The site list was NOT saved on this PC (' + $sv.why + ').') 'Red' }
  if ($sv.drive -eq $true) { Say ('Saved the site list to the site''s Drive folder (Docs\WireIt site list.json).') 'Green' }
  elseif ($sv.drive -eq $false) { Say ('Could not write to the Drive folder (' + $sv.driveWhy + ')' + $(if ($sv.local) { ' - saved on this PC: ' + $localList } else { '' })) 'Yellow' }
  elseif ($sv.local) { Say ('Saved on this PC (no Drive folder found for "' + $Site + '"): ' + $localList + '. Copy it into the site''s Drive folder, Docs.') 'Yellow' }
}
# 2.2.1 (review M5): what Hikvision's official reset needs (form details, reply relay, upload key, a browser) is said on the plan screen, before the YES
$hikNeed = @(@($plan.nvrs | Where-Object { $_.steps -contains 'reset' }) + @($plan.cams | Where-Object { $_.state -eq 'fix' -and $_.steps -contains 'reset' -and $_.brand -eq 'Hikvision' }))
if ($hikNeed.Count -and $hikFlowOk -and $Mode -in @('Fix', 'Plan')) { foreach ($hw in @(Get-HikReadiness (Get-HikConfig $cfgAll $here) $here)) { Say ('  Hikvision reset: ' + $hw) 'Yellow' } }
if (-not $work.Count) {
  Say ''; Say 'Nothing for the Toolkit to change.' 'Green'
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'missing' })) { Say ('  Go check: ' + $c.name + ' - ' + ($c.why -join '; ')) 'Yellow' }
  foreach ($l in @(Get-FsManualLines $plan)) { Say ('  ' + $l) 'Yellow' }
  Offer-List; Done $(if (@($plan.cams | Where-Object { $_.state -in @('missing', 'manual') }).Count -or @(Get-FsManualLines $plan).Count) { 4 } else { 0 })
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
# 2.2.6 (Codex file-by-file D): the undo file is written BEFORE each change it describes. A write that fails is never ignored: the run
# stops right there (exit 7), so nothing is changed that Undo would not know about (2.2.5 wrote it with Set-Content and went on).
function Save-Rb {
  try { Write-FsFileAtomic $rbPath ($rb | ConvertTo-Json -Depth 8) }   # 2.2.7 (F03): never truncates the undo file already on disk
  catch {
    $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
    Say ('The undo file could not be saved (' + $ex.Message + '), so the run stopped here: nothing more was changed.') 'Red'
    Fs-Log ('undo file write failed: ' + $ex.Message); Done 7
  }
}
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
Save-Rb   # 2.2.6: the undo file exists (and can be written) before the first change; if not, nothing is changed

# =====================================================================================
#  2.1.0  HIKVISION OFFICIAL RESET: every Hik device nobody can log in to (NVR and cameras), automatic up to the page's picture check
# =====================================================================================
$hikFixed = @{}      # mac -> $true when the official reset set the site password
$hikPending = @{}    # mac -> 'waiting for Hikvision's reply' / reason
# 2.2.14 (Codex 2.2.13 F2): the reset CHANGES a camera's password, so every camera passes the recorder/channel guard first
# (Get-FsHikResetTargets in FixSiteCore, the same selection the tests drive). A blocked camera is not reset: its reason is what the
# camera's own line says (Still a problem, nonzero exit). The selection runs also under -MockUrl, so the guard is tested there.
$hikSel = $null
if ($hikFlowOk -and $Mode -ne 'DryRun') {
  $rsCred = @{}; foreach ($k in @($nvrPw.Keys)) { $rsCred[$k] = 'known' }
  $rsLive = { param($rn) $rbr = 'Hikvision'; $rnp = @($plan.nvrs | Where-Object { $_.ip -eq $rn -or $_.target -eq $rn }) | Select-Object -First 1; if ($rnp -and $rnp.brand) { $rbr = [string]$rnp.brand }; return [string](Test-FsLogin $rn $rbr $nvrPw[$rn]) }
  $hikSel = Get-FsHikResetTargets $plan $rsCred $rsLive
  foreach ($bk in @($hikSel.blocked)) { if ($bk.mac) { $hikPending[[string]$bk.mac] = [string]$bk.why }; Fs-Log ('official reset blocked for ' + $bk.ip + ': ' + $bk.why) }
}
if ($hikFlowOk -and $Mode -ne 'DryRun' -and -not $MockUrl) {
  $hikT = @($hikSel.targets)
  if ($hikT.Count) {
    Say ''; Say ('----- Hikvision official password reset: ' + $hikT.Count + ' device(s) (NVR and cameras alike; no power-cycle, no reset button) -----') 'Cyan'
    $script:HkSay = { param($t, $c) if ($c) { Say $t $c } else { Say $t } }
    $script:HkAsk = { param($t) Ask $t }
    $script:SadpLog = { param($l) Fs-Log $l }
    $hikCfg = Get-HikConfig $cfgAll $here   # 2.2.0: reply relay (no mail password on this PC) + the "I got Hik's email" button
    $hikState = Join-Path $SecretsDir ('hikreset-' + (Get-FsSiteSlug $siteName))
    # 2.2.20 (Codex 2.2.19 class B/C, second pass): "the site password works" only on the device the reset record names ($D: MAC, else serial)
    $verify = { param($ip, $p, $D) return [bool](Test-FsHikResetLogin $ip $p $D) }
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
  if (-not (Test-FsBackupComplete $nbf 'Hikvision' -Nvr)) { & $nvrFail ('backup FAILED (' + $script:FsBackupWhy + ') - NVR not moved'); continue }
  $net = Get-FsNet $n.ip 'Hikvision' $cr
  if (-not $net) { & $nvrFail 'its address settings could not be read - not moved'; continue }
  # 2.2.20 (Codex 2.2.19 R09): Undo needs every old value (mask, mode, router, DNS 1 / 2); one missing from its answer = not moved
  $gapN = Get-FsNetUndoGap $net; if ($gapN) { & $nvrFail ('NOT moved: ' + $gapN + '. Nothing was changed'); continue }
  # 2.2.16 (Codex 2.2.15 F3): WHICH NVR this is (MAC / serial) goes into the undo file, so Undo never moves another NVR that takes the address
  $nid = Get-FsNvrIdRecord $n.ip $cr
  if (-not $nid.mac -and -not $nid.serial) { & $nvrFail 'its MAC / serial could not be read, so Undo could not check it is the same NVR later - not moved'; continue }
  # 2.2.19 (Codex 2.2.18 F03): the recorder answering now must be the one the SCAN found (its MAC), not only "some NVR that logs in":
  # a replacement recorder on the same address and password is never moved or changed
  $fwN = Get-FsFwdNvrBlock $n.ip $cr ([string]$n.mac) '' $nid
  if ($fwN) { & $nvrFail ('NOT moved: ' + $fwN + '. Nothing was changed - scan again'); continue }
  $taken = @($plan.cams | ForEach-Object { [string]$_.target; [string]$_.ip }) + @($plan.nvrs | Where-Object { $_ -ne $n } | ForEach-Object { [string]$_.target; [string]$_.ip })
  $t = $(if ($n.target -eq $n.ip) { $n.ip } else { Get-FsNvrMoveTarget $n.target $plan.scheme $opts.nvrHosts $taken })   # same address = only its network settings are fixed (#30)
  if (-not $t) { & $nvrFail ('not moved: ' + $n.target + ' (and the other NVR addresses) already answer on the network'); continue }
  if ($t -ne $n.target) { Say ('NVR ' + $n.ip + ': ' + $n.target + ' is already used by another device - moving it to ' + $t + ' instead') 'Yellow'; $n.target = $t }
  $rb.nvrs += [ordered]@{ ip = $n.ip; target = $n.target; mac = [string]$nid.mac; serial = [string]$nid.serial; iface = $net.iface; old = [ordered]@{ ip = $net.ip; mask = $net.mask; gw = $net.gw; dhcp = $net.dhcp; dns1 = $net.dns1; dns2 = $net.dns2 } }; Save-Rb
  # 2.2.7 (Codex file-by-file F02): its login is saved under the NEW address too before it moves, so a run stopped mid-move
  # still lets Undo log in there (2.2.6 saved it only after the move was verified: Undo said "no saved login")
  if (-not $sec.nvr.ContainsKey($n.target)) { $sec.nvr[$n.target] = $nvrPw[$n.ip]; Save-FsSecrets $SecretsDir $sec }
  # 2.2.19 (Codex 2.2.18 F02/F03): right before the address write: still the scanned recorder (fresh MAC), and the new address still free
  $fwN2 = Get-FsFwdNvrBlock $n.ip $cr ([string]$n.mac) ''
  if ($fwN2) { & $nvrFail ('NOT moved: ' + $fwN2 + '. Nothing was changed - scan again'); continue }
  if ($n.target -ne $n.ip -and -not (Test-FsIpFree $n.target)) { & $nvrFail ('NOT moved: ' + $(if ($script:FsIpFreeWhy) { $script:FsIpFreeWhy } else { $n.target + ' started answering on the network just now (another device took it)' }) + '. Nothing was changed - run it again'); continue }
  $w = Set-FsNet $n.ip 'Hikvision' $cr $net $n.target $devNet.mask $devNet.gw
  if ($w.ok -and $w.reboot) { [void](Restart-FsDeviceChecked $n.ip 'Hikvision' $cr ([string]$n.mac) '' 'the NVR the scan found' 'the scan') }   # 2.2.21 (F02)
  $answers = $w.ok -and (Wait-FsDevice $n.target 'Hikvision' $nvrPw[$n.ip] ([int]$opts.rebootWaitSec))
  # 2.2.19 (F03): the recorder that answers on the new address must be the scanned one (fresh MAC) before it counts as moved
  if ($answers) { $fwN3 = Get-FsFwdNvrBlock $n.target (Fs-Cred $nvrPw[$n.ip]) ([string]$n.mac) ''; if ($fwN3) { $answers = $false; $w = [pscustomobject]@{ ok = $true; reboot = $false; idWhy = $fwN3 } } }
  # 2.2.18 (Codex F3): logging in at the address is not proof the settings took (an in-place router / DNS / mask / DHCP fix already
  # logged in before): the whole network config is read back and every field asked for must match before it says "fixed"
  $nmF = $(if ($answers) { Get-FsNetMismatch $n.target 'Hikvision' (Fs-Cred $nvrPw[$n.ip]) $net $n.target $devNet.mask $devNet.gw } else { '' })
  $back = $answers -and -not $nmF
  $l = Format-FsCheckLine ('NVR ' + $n.ip) @([pscustomobject]@{ text = $(if (-not $w.ok) { $(if ($w.PSObject.Properties['why'] -and $w.why) { 'NOT moved: ' + $w.why } else { 'the NVR refused the new address settings' }) } elseif ($w.PSObject.Properties['idWhy'] -and $w.idWhy) { 'new address sent, but NOT confirmed: ' + $w.idWhy } elseif ($nmF) { $(if ($n.target -eq $n.ip) { 'network settings NOT fixed' } else { 'moved -> ' + (Get-FsShort $n.target) + ', but its network settings are NOT confirmed' }) + ' - the NVR accepted them, but reads back: ' + $nmF } elseif ($n.target -eq $n.ip) { 'network settings fixed (router ' + $devNet.gw + ', fixed address)' } else { 'moved -> ' + (Get-FsShort $n.target) }); ok = $back })
  Say $l $(if ($back) { 'Green' } else { 'Red' }); $results += $l
  if ($answers) { $nvrPw[$n.target] = $nvrPw[$n.ip]; $sec.nvr[$n.target] = $nvrPw[$n.ip]; Save-FsSecrets $SecretsDir $sec }; if ($back) { $okCount++ } else { $badCount++ }; $n | Add-Member -NotePropertyName moved -NotePropertyValue ([bool]$answers) -Force   # 2.2.18: moved = it answers there (the cameras follow it); fixed = also every setting read back
}
# 2.0.3: NVR password -> the site password (factory password at a new site, or the option ticked). Channels keep the camera logins.
$rb.nvr_passwords = @()
foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'password' })) {
  $nip = $(if ($n.target -and $nvrPw.ContainsKey($n.target)) { $n.target } else { $n.ip })
  if (-not $nvrPw.ContainsKey($nip)) { $l = 'NVR ' + $nip + ': no NVR login, so its password was not changed ' + $script:FsBad; Say $l 'Red'; $results += $l; $badCount++; continue }
  $oldN = $nvrPw[$nip]
  if ($oldN -ceq $sitePw) { Say ('NVR ' + $nip + ': already on the site password ' + $script:FsOk) 'Green'; continue }
  # 2.2.16 (Codex 2.2.15 F3): WHICH NVR this is goes into the undo file first; Undo checks it before it puts the old password back
  $nid = Get-FsNvrIdRecord $nip (Fs-Cred $oldN)
  if (-not $nid.mac -and -not $nid.serial) { $l = 'NVR ' + $nip + ': its MAC / serial could not be read, so Undo could not check it is the same NVR later - password NOT changed ' + $script:FsBad; Say $l 'Red'; $results += $l; $badCount++; continue }
  # 2.2.19 (Codex 2.2.18 F03): only the recorder the scan found (its MAC) gets the site password
  $fwP = Get-FsFwdNvrBlock $nip (Fs-Cred $oldN) ([string]$n.mac) '' $nid
  if ($fwP) { $l = 'NVR ' + $nip + ': password NOT changed - ' + $fwP + ' ' + $script:FsBad; Say $l 'Red'; $results += $l; $badCount++; continue }
  $sec.rollback[$stamp]['nvr|' + $nip] = $oldN; Save-FsSecrets $SecretsDir $sec
  $np = [ordered]@{ ip = $nip; changed = $false; mac = [string]$nid.mac; serial = [string]$nid.serial }; $rb.nvr_passwords += $np; Save-Rb
  $np.attempted = $true; Save-Rb
  $fwP2 = Get-FsFwdNvrBlock $nip (Fs-Cred $oldN) ([string]$n.mac) ''   # 2.2.19 (F03): fresh, right before the write
  if ($fwP2) { $np.attempted = $false; Save-Rb; $l = 'NVR ' + $nip + ': password NOT changed - ' + $fwP2 + ' ' + $script:FsBad; Say $l 'Red'; $results += $l; $badCount++; continue }
  [void](Set-FsPassword $nip 'Hikvision' (Fs-Cred $oldN) $sitePw)
  Say-PlainWarning $nip
  $pwState = Resolve-FsPwChange $nip 'Hikvision' $sitePw $oldN ([string]$nid.mac) ([string]$nid.serial)   # 2.2.3 (Codex #19); 2.2.20 (R12): the saved NVR's DeviceInfo, not HTTP 200
  if ($pwState -eq 'changed') { $nvrPw[$nip] = $sitePw; $sec.nvr[$nip] = $sitePw; $np.changed = $true; Save-FsSecrets $SecretsDir $sec; Save-Rb; $l = Format-FsCheckLine ('NVR ' + $nip) @([pscustomobject]@{ text = 'site password set'; ok = $true }); $okCount++ }
  elseif ($pwState -eq 'unknown') { $np.changed = $true; $np.unconfirmed = $true; $nvrPw.Remove($nip); Save-Rb; $l = Format-FsCheckLine ('NVR ' + $nip) @([pscustomobject]@{ text = 'password change not confirmed: neither password logs in right now - check the NVR'; ok = $false }); $badCount++ }
  else { $l = Format-FsCheckLine ('NVR ' + $nip) @([pscustomobject]@{ text = 'the NVR refused the new password - it keeps its old one'; ok = $false }); $badCount++ }
  $results += $l; Say $l $(if ($np.changed) { 'Green' } else { 'Red' })
}
# Use the VERIFIED address, including a different free target picked at the live check, or the original address after failure.
Resolve-FsPlanNvrAddresses $plan
$nvrCred = @{}; foreach ($k in @($nvrPw.Keys)) { $nvrCred[$k] = Fs-Cred $nvrPw[$k] }
# 2.2.19 (Codex 2.2.18 F03): the MAC the scan found for the NVR at $nvrIp (its old or new address); '' = the scan has none
function Get-FsPlanNvrMac([string]$nvrIp) { $p = @($plan.nvrs | Where-Object { $_ -and ([string]$_.ip -eq $nvrIp -or [string]$_.target -eq $nvrIp) }) | Select-Object -First 1; if ($p) { return [string]$p.mac }; return '' }
# 2.2.19 (Codex 2.2.18 F03): before a camera fix writes to its NVR: the identity just read ($id, fresh) must be the recorder the scan
# found AND the one this camera's undo entry recorded ($rbc.nvr_id). '' = fine, else the plain reason.
function Get-FsCamNvrWriteBlock([string]$nvrIp, $id, $rbcE) {
  $why = Get-FsFwdNvrBlock $nvrIp $null (Get-FsPlanNvrMac $nvrIp) '' $id
  if ($why) { return $why }
  $rec = $null; if ($rbcE -is [System.Collections.IDictionary] -and $rbcE.Contains('nvr_id')) { $rec = $rbcE['nvr_id'] }
  if ($rec) { $rm = ConvertTo-FsMac ([string]$rec['mac']); $rs = [string]$rec['serial']
    if ($rm -and $rm -ne [string]$id.mac) { return ('the recorder at ' + $nvrIp + ' is not the one recorded earlier in this run (MAC ' + $id.mac + ', recorded ' + $rm + ')') }
    if (-not $rm -and $rs -and $rs -ne [string]$id.serial) { return ('the recorder at ' + $nvrIp + ' is not the one recorded earlier in this run (serial ' + $id.serial + ', recorded ' + $rs + ')') } }
  return ''
}
function Undo-CamPassword($c, [string]$ip, [string]$oldPw) {
  # 2.0.3: the picture did not come back after the password change: the camera's old password goes back on it AND on its NVR channel
  # 2.2.17 (Codex 2.2.16 note): the in-run undo writes to the NVR too, so it follows the same rule as Undo: the NVR answering now must be
  # the one recorded before the change (MAC / serial). If it cannot be confirmed, nothing is written (camera or NVR) and the tech is told.
  if ($c.nvr -and $nvrCred.ContainsKey($c.nvr) -and [int]$c.channel) {
    $idw = [string](Get-FsUndoNvrBlock $c.nvr $nvrCred[$c.nvr] $rbc.nvr_id)
    if ($idw) { return [pscustomobject]@{ ok = $false; video = $false; why = ('NVR ' + $c.nvr + ' not confirmed: ' + $idw + '. Nothing was put back') } }
  }
  # 2.2.19 (Codex 2.2.18 class A): the camera answering at $ip must still be this camera (fresh MAC) before its password is written
  $idc = [string](Get-FsUndoIdentityBlock $ip ([string]$c.brand) (Fs-Cred $sitePw) ([string]$c.mac) ([string](Get-FsProp $c 'serial' '')) 'this camera' 'the scan')
  if ($idc) { return [pscustomobject]@{ ok = $false; video = $false; why = ($idc + '. Nothing was put back') } }
  $okP = Set-FsPassword $ip $c.brand (Fs-Cred $sitePw) $oldPw
  if ($okP) { $okP = ((Test-FsLoginIs $ip $c.brand $oldPw ([string]$c.mac) ([string](Get-FsProp $c 'serial' ''))) -eq 'ok') }   # 2.2.20 (R12): on THIS camera
  $okN = $true
  if ($okP -and $c.nvr -and $nvrCred.ContainsKey($c.nvr) -and [int]$c.channel -and [string](Get-FsUndoNvrBlock $c.nvr $nvrCred[$c.nvr] $rbc.nvr_id)) { $okN = $false }   # 2.2.19: fresh again right before the channel write
  elseif ($okP -and $c.nvr -and $nvrCred.ContainsKey($c.nvr) -and [int]$c.channel) { $w = Set-FsNvrChannel $c.nvr $nvrCred[$c.nvr] ([int]$c.channel) $ip $oldPw $c.brand ''; $okN = [bool]$w.ok }
  $vid = $false
  if ($okP) { $end = (Get-Date).AddSeconds($(if ($script:FsMockUrl) { 8 } else { 90 })); do { $vid = Test-FsVideo $c.nvr $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { $nvrCred[$c.nvr] } else { $null }) $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { [int]$c.channel } else { 0 }) $ip $c.brand (Fs-Cred $oldPw); if (-not $vid) { Fs-Sleep 5 } } while (-not $vid -and (Get-Date) -lt $end) }
  return [pscustomobject]@{ ok = [bool]($okP -and $okN); video = [bool]$vid; why = '' }
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
  $res = New-Object System.Collections.ArrayList; $ip = $c.ip; $pw = $(if ($pwFor.ContainsKey($c.ip)) { $pwFor[$c.ip] } else { '' }); $stop = $false; $needReboot = $false; $streamCheck = $null
  $rbc = [ordered]@{ name = $c.name; mac = $c.mac; serial = [string](Get-FsProp $c 'serial' ''); brand = $c.brand; ip_before = $c.ip; ip_after = ''; net_before = $null; stream_before = $null; password_changed = $false; nvr = $null; backup = '' }
  $rb.cameras += $rbc
  $step = { param($text, $ok) [void]$res.Add([pscustomobject]@{ text = $text; ok = $ok }); Say ('    ' + $text + ' ' + $(if ($ok -eq $true) { $script:FsOk } elseif ($ok -eq $false) { $script:FsBad } else { '' })) }
  # 2.2.19 (Codex 2.2.18 class A): before EVERY write to this camera (password, settings, address, restart, its NVR channel) the device
  # answering at $ip is read FRESH and must be the camera the scan found (its MAC; serial only when the scan has no MAC). Another
  # device, or one that does not tell = that write is not done (NOT changed, Still a problem) and nothing after it either.
  $camSerF = [string](Get-FsProp $c 'serial' '')
  $camGate = { param($what) $why = [string](Get-FsUndoIdentityBlock $ip ([string]$c.brand) $cr ([string]$c.mac) $camSerF 'the camera the scan found' 'the scan'); if ($why) { & $step ($what + ' NOT done: ' + $why + ' - camera left as it is') $false; return $false }; return $true }
  if (-not (Test-FsOnScheme $ip $plan.scheme)) { [void](Add-FsTempIp (Get-FsP3 $ip) $pc $tempState) }
  # hung: power first
  if ($c.steps -contains 'poe' -or $c.steps -contains 'unplug') {
    $done = $false
    if ($c.steps -contains 'poe') { $pr = Invoke-FsPoeCycle $siteId $c.mac $portMapDir; if ($pr.state -eq 'done') { & $step ('power-cycled ' + $c.switch + ' port ' + $c.port) $true; $done = $true } elseif ($pr.state -ne 'unavailable') { & $step ('switch power-cycle: ' + $pr.msg) $false } }
    if (-not $done) { $a = Ask ($c.name + ': unplug its network cable' + $(if ($null -ne $c.port) { ' at ' + $(if ($c.switch) { $c.switch + ' ' } else { 'switch ' }) + 'port ' + $c.port } else { '' }) + ' for 10 seconds, plug it back in, then press Enter (S = skip).'); if ($a -match '^(?i)s') { & $step 'skipped' $null; $stop = $true } else { & $step 'unplugged and plugged back' $null } }
    if (-not $stop) {
      $up = $false; $end = (Get-Date).AddSeconds([int]$opts.rebootWaitSec); do { Fs-Sleep 5; $s = Test-FsLogin $ip $c.brand ''; if ($s -ne 'noanswer') { $up = $true } } while (-not $up -and (Get-Date) -lt $end)
      if (-not $up) { & $step 'still not answering' $false; $stop = $true }
      else { $fp = Find-FsPassword $ip $c.brand @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries) $c.mac (Get-NewSiteDefaults $c.brand)) ([int]$opts.maxPasswordTries); if ($fp.state -eq 'ok') { $pw = $fp.value; if ($pw -cne $sitePw -and $c.steps -notcontains 'password') { $c.steps = @($c.steps | ForEach-Object { if ($_ -eq 'backup') { 'backup'; 'password' } else { $_ } }) } } else { $c.steps = @($c.steps) + @('reset') } }
    }
  }
  if (-not $stop -and ($c.steps -contains 'reset' -or $c.steps -contains 'activate')) {
    if (Human-Reset $c) { $pw = $sitePw; & $step $(if ($c.steps -contains 'activate') { 'activated with the site password' } else { 'password reset (official)' }) $true } else { & $step 'password not reset - skipped' $false; $stop = $true }
  }
  if (-not $stop -and -not $pw) { & $step 'no password that works' $false; $stop = $true }
  $cr = Fs-Cred $pw
  # backup
  if (-not $stop) { $bd = Join-Path $runDir ('backup\' + (($c.name -replace '[^A-Za-z0-9_-]+', '_') + '-' + ($c.mac -replace ':', ''))); $bf = @(Save-FsBackup $ip $c.brand $cr $bd); $rbc.backup = $bd; if (Test-FsBackupComplete $bf $c.brand) { & $step 'backup saved' $true } else { & $step ('backup FAILED (' + $script:FsBackupWhy + ') - camera left alone') $false; $stop = $true } }
  # 2.2.12 (Codex 2.2.11 #2): no change at all to a camera unless its complete, valid network settings are in the undo file first
  # (a failed or half read is never journaled; the camera is left alone and the tech is told to run again)
  if (-not $stop) {
    $nb = Get-FsNet $ip $c.brand $cr
    if ($nb) { $rbc.net_before = [ordered]@{ ip = $nb.ip; mask = $nb.mask; gw = $nb.gw; dhcp = $nb.dhcp; dns1 = $nb.dns1; dns2 = $nb.dns2; iface = $nb.iface }; Save-Rb }
    else { Save-Rb; & $step ('its network settings could not be read (' + $script:FsNetWhy + ') - camera left alone, nothing changed. Run Fix this site again') $false; $stop = $true }
  }
  if (-not $stop -and -not (& $camGate 'any change')) { $stop = $true }   # 2.2.19: the camera the scan found, before the first write
  # 2.2.17 (Codex 2.2.16 re-review): a camera fix that will write to its NVR - the new password on the NVR channel, a move the channel
  # follows, or the channel put back - first reads and records WHICH NVR that is (MAC / serial), the same identity Undo checks before
  # it writes to an NVR (2.2.16 F3). If the NVR does not tell it, nothing is changed on the camera or the NVR (Still a problem).
  $nvrWrite = ($c.nvr -and $nvrCred.ContainsKey($c.nvr) -and (($c.steps -contains 'nvr') -or ($pw -cne $sitePw -and ($c.steps -contains 'password' -or $opts.passwordAll)) -or (($c.steps -contains 'move') -and $c.target -and $c.target -ne $ip)))
  if (-not $stop -and $nvrWrite) {
    $nidPre = Get-FsNvrIdRecord $c.nvr $nvrCred[$c.nvr]
    if (-not $nidPre.mac -and -not $nidPre.serial) {
      # an NVR that does not answer at all is told as that (the old "does not answer right now" words), not as a missing MAC / serial
      $nst = $(if ($nvrPw.ContainsKey($c.nvr)) { Test-FsLogin $c.nvr 'Hikvision' $nvrPw[$c.nvr] } else { 'ok' })
      if ($nst -ne 'ok') { Save-Rb; & $step ('NOT changed: NVR ' + $c.nvr + ' records this camera and does not answer right now (' + $nst + '), so its MAC / serial could not be read for Undo. Camera and NVR left as they were - run Fix this site again when it is back') $false; $stop = $true }
      else { Save-Rb; & $step ('NOT changed: NVR ' + $c.nvr + ' records this camera but did not tell its MAC / serial, so Undo could not check later that it is the same NVR. Camera and NVR left as they were - check the NVR and run Fix this site again') $false; $stop = $true }
    } elseif ($fwG = Get-FsFwdNvrBlock $c.nvr $null (Get-FsPlanNvrMac $c.nvr) '' $nidPre) {
      # 2.2.19 (Codex 2.2.18 F03): the recorder answering now must be the one the scan found
      Save-Rb; & $step ('NOT changed: ' + $fwG + '. Camera and NVR left as they were - scan again') $false; $stop = $true
    } else { $rbc.nvr_id = [ordered]@{ nvr = $c.nvr; mac = [string]$nidPre.mac; serial = [string]$nidPre.serial }; Save-Rb }
  }
  # password
  if (-not $stop -and $pw -cne $sitePw -and ($c.steps -contains 'password' -or $opts.passwordAll)) {   # 2.2.3 (Codex #37): -cne
    # 2.2.3 (Codex #13): a camera recorded by an NVR keeps its password unless that NVR can be updated too (its login is known);
    # otherwise the NVR loses the picture and recording while a direct camera picture still looks fine.
    # 2.2.13 (Codex 2.2.12 #1): the guard uses the COMPLETE recorder set (its NVR, the NVR the saved site list names - it may be
    # offline today - and every NVR channel the scan found pointing at it), the same set the move guard uses. The password is only
    # changed when that set is ONE recorder that answers right now with a known login, so it can be updated AND checked (channel
    # updated, video back on it). Anything else: the camera keeps its old password (Still a problem, nonzero exit), and since the
    # same set stops a move, the password is never changed ahead of a move that is then refused.
    $pwRecs = @(Get-FsCamRecorders $c); $pwBlock = ''
    if (-not ($c.nvr -and -not $nvrCred.ContainsKey($c.nvr))) { $pwBlock = Get-FsPwChangeBlock $c $pwRecs $nvrCred }
    if (-not $pwBlock -and $pwRecs.Count -eq 1 -and $nvrCred.ContainsKey([string]$pwRecs[0])) {
      $rn = [string]$pwRecs[0]; $rbr = 'Hikvision'; $rnp = @($plan.nvrs | Where-Object { $_.ip -eq $rn -or $_.target -eq $rn }) | Select-Object -First 1
      if ($rnp -and $rnp.brand) { $rbr = [string]$rnp.brand }
      $rst = Test-FsLogin $rn $rbr $nvrPw[$rn]
      if ($rst -ne 'ok') { $pwBlock = 'password not changed: NVR ' + $rn + ' records this camera and does not answer right now (' + $rst + ') - it could not be updated and checked. Run Fix this site again when it is back' }
    }
    if ($c.nvr -and -not $nvrCred.ContainsKey($c.nvr)) { & $step ('password not changed: NVR ' + $c.nvr + ' records this camera and its login is unknown (or it did not answer at the scan) - it could not be updated and checked') $false }
    elseif ($pwBlock) { & $step $pwBlock $false }
    elseif ((Test-FsLogin $ip $c.brand $sitePw) -eq 'ok') { $pw = $sitePw; $cr = Fs-Cred $pw; & $step 'password already set' $true }
    elseif (-not (& $camGate 'password change')) { $stop = $true }
    else {
      $sec.rollback[$stamp][$c.mac + '|' + $c.ip] = $pw; Save-FsSecrets $SecretsDir $sec; $pwBefore = $pw
      $rbc.password_attempted = $true; Save-Rb
      [void](Set-FsPassword $ip $c.brand $cr $sitePw)
      # 2.2.3 (Codex #19): the answer to the write may be lost while the change took: decide from what logs in now, never from the answer
      $pwState = Resolve-FsPwChange $ip $c.brand $sitePw $pwBefore ([string]$c.mac) $camSerF; $mk = ConvertTo-FsMac $c.mac   # 2.2.20 (R12)
      if ($pwState -eq 'changed') { $pw = $sitePw; $cr = Fs-Cred $pw; $rbc.password_changed = $true; if ($mk) { $sec.cams[$mk] = $sitePw; Save-FsSecrets $SecretsDir $sec }; & $step $(if (Test-FsSentPlain $ip) { 'password set' } else { 'password set (over HTTPS)' }) $true }
      elseif ($pwState -eq 'unchanged') { & $step 'password not changed (old one still works)' $false }
      else { $rbc.password_changed = $true; $rbc.password_unconfirmed = $true; if ($mk) { $sec.cams[$mk] = $sitePw; Save-FsSecrets $SecretsDir $sec }; & $step 'password change not confirmed: neither password logs in right now (it may have the site password) - camera left, check it' $false; $stop = $true }
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
      # 2.2.12 (Codex 2.2.11 #4): a green check only when the camera's own settings, read back, have what was asked (after its
      # restart when the write needs one); an accepted write is not proof
      # 2.2.19 (Codex 2.2.18 F19): a setting that was asked for but the camera does not report is NOT CHECKED - never "already right";
      # nothing is written while any asked-for field is unknown
      $unkF = Format-FsUnknownFields $diff
      if ($unkF) { & $step ('settings NOT CHECKED: the camera did not report its ' + $unkF + ', so it is not known whether they are right - nothing changed') $false }
      elseif ($diff.Count -and -not (& $camGate 'settings change')) { $stop = $true }
      elseif ($diff.Count) {
        $w = Set-FsStream $ip $c.brand $cr $cur $diff ([string]$c.mac) $camSerF 'the scan'
        if (-not $w.ok -and $w.PSObject.Properties['why'] -and $w.why) { & $step ('settings NOT done: ' + $w.why + ' - camera left as it is') $false; $stop = $true }
        elseif (-not $w.ok) { & $step ((Format-FsSettingsDiff $diff) + ' - the camera refused the settings') $false }
        elseif ($w.reboot) { $needReboot = $true; $streamCheck = $diff }
        else { $mis = @(Get-FsStreamMismatch (Get-FsStream $ip $c.brand $cr) $diff); if ($mis.Count) { & $step ('settings NOT confirmed: ' + ($mis -join '; ')) $false } else { & $step (Format-FsSettingsDiff $diff) $true } }
      } else { & $step 'settings already right' $true }
    } else { & $step 'settings could not be read - not changed' $false }
  }
  # address
  if (-not $stop -and ($c.steps -contains 'move') -and $c.target) {
    $net = Get-FsNet $ip $c.brand $cr
    if ($net -and $net.ip -eq $c.target -and -not $net.dhcp) { & $step ('already on ' + (Get-FsShort $c.target)) $true }
    elseif ($net -and $c.target -ne $ip -and (Get-FsMoveBlock $c)) {
      # 2.2.12 (Codex 2.2.11 #1): a camera recorded by more than one NVR is never moved: only one NVR would be updated and checked,
      # the others would silently lose its video. The tech hears it plainly; the camera stays where it is (Still a problem).
      # 2.2.14 (Codex 2.2.13 F1): the same for more than one CHANNEL of one NVR (Get-FsMoveBlock counts recorders AND channels;
      # its words: 'NOT moved: N NVRs record this camera' / 'N NVR channels record this camera')
      & $step ([string](Get-FsMoveBlock $c)) $false
    }
    elseif ($net -and (Get-FsNetUndoGap $net)) { & $step ('NOT moved: ' + (Get-FsNetUndoGap $net) + ' - nothing was changed') $false }   # 2.2.20 (Codex 2.2.19 R09)
    elseif ($net) {
      $t = $c.target
      if ($t -ne $ip -and -not (Test-FsIpFree $t)) { $t = ''; for ($n = [int]$opts.camFirst; $n -le [int]$opts.camLast; $n++) { $x = $plan.scheme + '.' + $n; if (-not @($plan.cams | Where-Object { $_.target -eq $x -or $_.ip -eq $x }).Count -and (Test-FsIpFree $x)) { $t = $x; break } } }
      if (-not $t) { & $step $(if ($script:FsIpFreeWhy) { 'not moved: ' + $script:FsIpFreeWhy } else { 'no free address - not moved' }) $false }
      else {
        # 2.2.6 (Codex file-by-file E): the new address goes into the undo file BEFORE the move, so a run stopped mid-move still lets Undo find it
        $rbc.ip_target = $t; Save-Rb
        # 2.2.19 (Codex 2.2.18 F02 sweep): right before the address write: still the scanned camera, and the new address still free
        $mvOk = (& $camGate 'move')
        if ($mvOk -and $t -ne $ip -and -not (Test-FsIpFree $t)) { & $step ('NOT moved: ' + $(if ($script:FsIpFreeWhy) { $script:FsIpFreeWhy } else { (Get-FsShort $t) + ' started answering on the network just now (another device took it)' }) + ' - camera left on ' + (Get-FsShort $ip)) $false; $mvOk = $false }
        if (-not $mvOk) { $rbc.ip_target = ''; Save-Rb; $stop = $true; $w = [pscustomobject]@{ ok = $false; reboot = $false; skipped = $true } }
        else { $w = Set-FsNet $ip $c.brand $cr $net $t $devNet.mask $devNet.gw }
        if ($w.ok -and $w.reboot) { [void](Restart-FsDeviceChecked $ip $c.brand $cr ([string]$c.mac) $camSerF 'the camera the scan found' 'the scan') }   # 2.2.21 (F02)
        $back = $w.ok -and (Wait-FsDevice $t $c.brand $pw ([int]$opts.moveWaitSec))
        if (-not $back -and $w.ok -and $t -ne $ip) {
          # 2.1.0 (3 Hewlett, cam .7 stayed on its old address): the new address was accepted but the camera did not move.
          # Look where it is. Still on the old address = restart it once (the address applies on restart) and wait again; never a second wrong-password try.
          $st0 = Test-FsLogin $ip $c.brand $pw
          if ($st0 -eq 'ok') {
            Say ('    still answering on ' + (Get-FsShort $ip) + ' - restarting it once so the new address takes') 'Yellow'
            [void](Restart-FsDeviceChecked $ip $c.brand $cr ([string]$c.mac) $camSerF 'the camera the scan found' 'the scan')   # 2.2.21 (F02)
            $back = Wait-FsDevice $t $c.brand $pw ([int]$opts.rebootWaitSec)
          }
        }
        # 2.2.18 (Codex F3 twin): answering on the new address is not proof every setting took: address, mask, router, DNS and fixed read back
        # 2.2.19 (Codex 2.2.18 F02 sweep): the device answering on the new address must be THIS camera (fresh MAC) before it counts as moved
        $idMv = $(if ($back) { [string](Get-FsUndoIdentityBlock $t ([string]$c.brand) $cr ([string]$c.mac) $camSerF 'the camera the scan found' 'the scan') } else { '' })
        if ($idMv) { $back = $false; $w = [pscustomobject]@{ ok = $false; reboot = $false; skipped = $true }; & $step ('new address ' + (Get-FsShort $t) + ' sent, but NOT confirmed: ' + $idMv + ' - check it by hand') $false; $stop = $true; $rbc.ip_after = $t }
        $nmC = $(if ($back) { Get-FsNetMismatch $t $c.brand $cr $net $t $devNet.mask $devNet.gw } else { '' })
        if ($back -and $nmC) { & $step ($(if ($t -ne $ip) { 'moved ' + (Get-FsShort $ip) + ' -> ' + (Get-FsShort $t) + ', but its network settings are NOT confirmed' } else { 'network settings NOT fixed' }) + ' - the camera accepted them, but reads back: ' + $nmC) $false; $ip = $t; $rbc.ip_after = $t; $c.target = $t; $c | Add-Member -NotePropertyName ipNow -NotePropertyValue $t -Force }
        elseif ($back) { & $step $(if ($t -ne $ip) { 'moved ' + (Get-FsShort $ip) + ' -> ' + (Get-FsShort $t) } else { 'address set fixed' }) $true; $ip = $t; $rbc.ip_after = $t; $c.target = $t; $c | Add-Member -NotePropertyName ipNow -NotePropertyValue $t -Force }
        elseif ($w.ok) { & $step ('moved to ' + (Get-FsShort $t) + ' but it does not answer there yet') $false; $stop = $true; $rbc.ip_after = $t }
        elseif ($w.PSObject.Properties['skipped']) { }
        elseif ($w.PSObject.Properties['why'] -and $w.why) { & $step ('NOT moved: ' + $w.why) $false }   # 2.2.20 (R09)
        else { & $step 'the camera refused the new address' $false }
      }
    } else { & $step 'address could not be read - not moved' $false }
    Save-Rb
  }
  # restart (settings that need it, or a camera with no video)
  if (-not $stop -and ($needReboot -or $c.steps -contains 'reboot') -and -not (& $camGate 'restart')) { $stop = $true }   # 2.2.19 (class A)
  if (-not $stop -and ($needReboot -or $c.steps -contains 'reboot')) { $ok = Restart-FsDevice $ip $c.brand $cr; if ($ok) { Fs-Sleep 20; $ok = Wait-FsDevice $ip $c.brand $pw ([int]$opts.rebootWaitSec) }; & $step 'restarted' $ok }
  if ($streamCheck) {
    # 2.2.12: settings that needed a restart are read back after it (a run stopped before the restart = not confirmed)
    if ($stop) { & $step ((Format-FsSettingsDiff $streamCheck) + ' sent, but NOT confirmed (the camera needs a restart that did not happen)') $false }
    else { $mis = @(Get-FsStreamMismatch (Get-FsStream $ip $c.brand $cr) $streamCheck); if ($mis.Count) { & $step ('settings NOT confirmed after the restart: ' + ($mis -join '; ')) $false } else { & $step (Format-FsSettingsDiff $streamCheck) $true } }
    $streamCheck = $null
  }
  # back on the NVR
  if (-not $stop -and ($c.steps -contains 'nvr') -and $c.nvr) {
    if (-not $nvrCred.ContainsKey($c.nvr)) { & $step ('NVR ' + $c.nvr + ' password unknown - put it on ch ' + $c.channel + ' by hand') $false }
    else {
      $ch = [int]$c.channel; $chWhy = ''
      # 2.2.15 (Codex 2.2.14 R1 follow-up): a free channel is picked only from a channel list that WAS read; an unread list never means "ch 1 is free"
      if (-not $ch) { $cl = Read-FsNvrChannelList $c.nvr $nvrCred[$c.nvr]; if (-not $cl.ok) { $chWhy = $cl.why } else { $chs = @($cl.channels); $ch = Get-FsFreeNvrChannel $chs $ip ([string]$rbc.ip_before); if (-not $ch) { $used = @($chs | ForEach-Object { $_.channel }); for ($k = 1; $k -le 64; $k++) { if ($used -notcontains $k) { $ch = $k; break } } } } }
    }
    if (-not $ch -and $nvrCred.ContainsKey($c.nvr)) { & $step ('NVR ' + $c.nvr + $(if ($chWhy) { ' channel list could not be read (' + $chWhy + ')' } else { ' has no free channel' }) + ' - NOT put on the NVR; add it there by hand') $false }
    elseif ($nvrCred.ContainsKey($c.nvr) -and -not ($nidC = Get-FsNvrIdRecord $c.nvr $nvrCred[$c.nvr]).mac -and -not $nidC.serial) {
      # 2.2.17: no NVR identity = no channel write (Undo could not check it is the same NVR)
      & $step ('NOT put on NVR ' + $c.nvr + ': it did not tell its MAC / serial, so Undo could not check later that it is the same NVR - add ch ' + $ch + ' there by hand') $false
    }
    elseif ($nvrCred.ContainsKey($c.nvr) -and ($nvW = Get-FsCamNvrWriteBlock $c.nvr $nidC $rbc)) {
      # 2.2.19 (Codex 2.2.18 F03): the recorder answering now (fresh read) must be the one the scan found and the one this run recorded
      & $step ('NOT put on NVR ' + $c.nvr + ' ch ' + $ch + ': ' + $nvW + ' - nothing written to it') $false
    }
    elseif ($nvrCred.ContainsKey($c.nvr) -and -not (& $camGate ('NVR ch ' + $ch + ' change'))) { $stop = $true }
    elseif ($nvrCred.ContainsKey($c.nvr)) {
      # 2.2.7 (Codex file-by-file F01): the channel goes into the undo file BEFORE the NVR is changed ("pending"); a run stopped
      # right after the NVR took the change still lets Undo put the channel back (its saved copy, or remove a channel it added)
      $nid = $nidC   # 2.2.16 (Codex 2.2.15 F3): which NVR, for Undo (read fresh just above)
      $rbc.nvr = [ordered]@{ nvr = $c.nvr; channel = $ch; action = 'pending'; before_file = ('backup\nvr-' + $c.nvr + '-ch' + $ch + '.xml'); nvr_mac = [string]$nid.mac; nvr_serial = [string]$nid.serial }; Save-Rb
      $w = Set-FsNvrChannel $c.nvr $nvrCred[$c.nvr] $ch $ip $pw $c.brand (Join-Path $runDir 'backup'); Say-PlainWarning $c.nvr
      $rbc.nvr = [ordered]@{ nvr = $c.nvr; channel = $ch; action = $w.action; before_file = $(if ($w.before) { 'backup\nvr-' + $c.nvr + '-ch' + $ch + '.xml' } else { '' }); nvr_mac = [string]$nid.mac; nvr_serial = [string]$nid.serial }; Save-Rb
      if ($w.why) { Say ('  ' + [string]$w.why) 'Red' }   # 2.2.10 (Codex R06): a channel showing another live camera is left alone, and the tech is told
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
      & $step $(if ($u.ok -and $u.video) { 'old password put back, video back - this camera stays on its old password' } elseif ($u.ok) { 'old password put back, but still no video - check it' } elseif ($u.why) { 'could NOT put the old password back (' + $u.why + ') - check it now' } else { 'could NOT put the old password back - check it now' }) $false
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
      # 2.2.18 (sweep A): the device that answers on the list address after the power cycle must be THIS camera (its MAC) before its
      # NVR channel is pointed there; a site password that logs in is not identity (another camera on the same password can hold it)
      # 2.2.19 (Codex 2.2.18 class A/C): checked FRESH every time it answers (also when no NVR channel is written: "answers again" is
      # said only of THIS camera); the NVR must be the one the scan found, read fresh right before the channel write.
      $camWhyM = $(if ($back) { [string](Get-FsUndoIdentityBlock $c.listIp $c.brand (Fs-Cred $sitePw) $c.mac ([string](Get-FsProp $c 'serial' '')) 'this camera' 'the site list') } else { '' })
      $nvrM = ($back -and -not $camWhyM -and $c.nvr -and $nvrCred.ContainsKey($c.nvr) -and $c.channel)
      $nidM = $(if ($nvrM) { Get-FsNvrIdRecord $c.nvr $nvrCred[$c.nvr] } else { $null })
      $nvwM = $(if ($nidM -and ($nidM.mac -or $nidM.serial)) { [string](Get-FsFwdNvrBlock $c.nvr $null (Get-FsPlanNvrMac $c.nvr) '' $nidM) } else { '' })
      if ($camWhyM) {
        $line = $c.name + ': power-cycled ' + $c.switch + ' port ' + $c.port + ', something answers on ' + $c.listIp + ', but it is NOT confirmed to be this camera: ' + $camWhyM + $(if ($c.nvr -and $c.channel) { ' - NOT put on NVR ' + $c.nvr + ' ch ' + $c.channel + '; check it by hand' } else { ' - check it by hand' }) + ' ' + $script:FsBad
      }
      elseif ($nidM -and -not $nidM.mac -and -not $nidM.serial) {
        # 2.2.17: no NVR identity = no channel write (Undo could not check it is the same NVR)
        $line = $c.name + ': power-cycled ' + $c.switch + ' port ' + $c.port + ', answers again, but NOT put on NVR ' + $c.nvr + ' ch ' + $c.channel + ': the NVR did not tell its MAC / serial, so Undo could not check later that it is the same NVR - check ch ' + $c.channel + ' by hand ' + $script:FsBad
      }
      elseif ($nvwM) {
        $line = $c.name + ': power-cycled ' + $c.switch + ' port ' + $c.port + ', answers again, but NOT put on NVR ' + $c.nvr + ' ch ' + $c.channel + ': ' + $nvwM + ' - check ch ' + $c.channel + ' by hand ' + $script:FsBad
      }
      elseif ($nvrM) {
        # 2.2.7 (F01): this channel change gets its own undo entry first, like every other change
        $nid = $nidM   # 2.2.16 (Codex 2.2.15 F3): which NVR, for Undo
        $rbm = [ordered]@{ name = $c.name; mac = $c.mac; brand = $c.brand; ip_before = $c.listIp; ip_after = ''; net_before = $null; stream_before = $null; password_changed = $false; recovered = $true; backup = ''
                           nvr = [ordered]@{ nvr = $c.nvr; channel = [int]$c.channel; action = 'pending'; before_file = ('backup\nvr-' + $c.nvr + '-ch' + [int]$c.channel + '.xml'); nvr_mac = [string]$nid.mac; nvr_serial = [string]$nid.serial } }
        $rb.cameras += $rbm; Save-Rb
        $w = Set-FsNvrChannel $c.nvr $nvrCred[$c.nvr] ([int]$c.channel) $c.listIp $sitePw $c.brand (Join-Path $runDir 'backup'); $rbm.nvr.action = $w.action; if (-not $w.before) { $rbm.nvr.before_file = '' }; Save-Rb
        if ($w.why) { Say ('  ' + [string]$w.why) 'Red' }
        $vid = $(if ($w.ok) { Test-FsVideo $c.nvr $nvrCred[$c.nvr] ([int]$c.channel) $c.listIp $c.brand (Fs-Cred $sitePw) } else { $false })
        $line = Format-FsCheckLine $c.name @([pscustomobject]@{ text = ('power-cycled ' + $c.switch + ' port ' + $c.port); ok = $true }, [pscustomobject]@{ text = $(if ($w.ok) { 'video back' } else { 'NOT put on NVR ch ' + $c.channel }); ok = [bool]$vid })
      }
      elseif ($back) { $line = Format-FsCheckLine $c.name @([pscustomobject]@{ text = ('power-cycled ' + $c.switch + ' port ' + $c.port + ', answers again'); ok = $true }) }
      else { $line = $c.name + ': power-cycled ' + $c.switch + ' port ' + $c.port + ', still missing - go check port ' + $c.port + ' (cable, camera)' + ' ' + $script:FsBad }
    } else { $line = $c.name + ': missing - ' + ($c.why -join '; ') + ' ' + $script:FsBad }
  } else { $line = $c.name + ': ' + ($c.why -join '; ') + ' ' + $script:FsBad }
  if ($line -like ('*' + $script:FsOk + '*') -and $line -notlike ('*' + $script:FsBad + '*')) { $okCount++ } else { $badCount++ }
  $results += $line; Say ('  ' + $line) $(if ($line -like ('*' + $script:FsBad + '*')) { 'Red' } else { 'Green' })
}
foreach ($l in @(Get-FsManualLines $plan)) { $results += $l; $badCount++ }   # 2.2.3 (Codex #42)
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
if (-not (Save-FsRunText (Join-Path $runDir 'summary.json') ([string]([ordered]@{ at = (Get-Date -Format 's'); site = $siteName; ok = $okCount; bad = $badCount; lines = $results } | ConvertTo-Json -Depth 4)))) { Say ('The run summary (summary.json) could NOT be saved in ' + $runDir + '; the checklist above is the record.') 'Yellow' }   # 2.2.20 (class A)
Offer-List
$pwUsed = $newPw -or @($rb.cameras | Where-Object { $_.password_changed }).Count -gt 0 -or @($rb.nvr_passwords | Where-Object { $_.changed }).Count -gt 0
if ($pwUsed -and -not $sec.bitwardenSaved) { Say ''; Save-SitePasswordAway $sitePw }
Fs-Log ('end ok=' + $okCount + ' bad=' + $badCount)
Done $(if ($badCount) { 4 } else { 0 })
