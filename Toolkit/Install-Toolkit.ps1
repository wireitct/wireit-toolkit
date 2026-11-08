<#
 Install-Toolkit.ps1 - puts the WireIt Toolkit on this PC (Windows PowerShell 5.1). Safe to run again.
 Run as administrator from the Toolkit folder:  powershell -ExecutionPolicy Bypass -File .\Install-Toolkit.ps1
 - makes C:\WireIt\Toolkit (logs\, previous\) and copies itself there if run from somewhere else (USB stick, Downloads)
 - copies NetCheck into C:\WireIt\NetCheck if it came along in .\bundle\NetCheck
 - desktop shortcut "WireIt Toolkit" (+ Start menu) with the WireIt icon
 - (2.2.0, admin only) locks C:\WireIt with icacls (Crew = read + execute; Administrators + SYSTEM = full control), makes the
   admin-owned "Fix this site" task the Crew login starts, moves 2.1's saved site passwords into the machine-wide vault\, and blanks the
   site-password word that 2.1 logged. Run this installer once as an admin on every PC (it is safe to run again).
 - camera-discovery firewall rules (UDP answers to PowerShell from the local network + SADP 37020) when run as admin and missing
 Nothing is downloaded and no password is asked or stored.
#>
param([string]$Root = 'C:\WireIt', [switch]$NoShortcut, [switch]$PlanOnly)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tk = Join-Path $Root 'Toolkit'
$files = 'WireItToolkit.ps1', 'ToolkitCore.ps1', 'WireIt Toolkit.cmd', 'Install-Toolkit.ps1', 'README.txt', 'wireit.ico', 'wireit-logo.png', 'version.json', 'CamViews.ps1', 'Set upload key.cmd', 'NvrCheck.ps1', 'ScanUpload.ps1', 'FixIt.ps1', 'FixSite.ps1', 'FixSiteCore.ps1', 'FixSiteDevices.ps1', 'FixSiteWindow.ps1', 'HikSadp.ps1', 'HikPortal.ps1', 'HikMail.ps1', 'HikReset.ps1', 'HikResetFlow.ps1', 'FixSiteIpc.ps1', 'FixSiteRunner.ps1', 'FixSiteAsk.ps1', 'HikEmailDrop.ps1', 'HikPortalStep.ps1', 'WireItAcl.ps1'
# 2.2.1 (review M3): the companion tools come from .\bundle\<tool> (a release zip) OR from beside the Toolkit folder (a copy of the
# repository: Toolkit\, FixNVR\, CamReset\, NetCheck\ side by side). Every file the Toolkit needs is checked BEFORE anything is
# installed; a missing one stops the install with its name (it used to be skipped and the install still said "installed").
function Get-TkInstallSource([string]$here, [string]$tool) {
  foreach ($c in @((Join-Path (Join-Path $here 'bundle') $tool), (Join-Path (Split-Path -Parent $here) $tool))) { if ($c -and (Test-Path -LiteralPath $c) -and ((Resolve-Path -LiteralPath $c).Path.TrimEnd('\', '/') -ne (Resolve-Path -LiteralPath $here).Path.TrimEnd('\', '/'))) { return $c } }
  return ''
}
$need = @{ 'FixNVR' = 'FixNVR.ps1'; 'CamReset' = 'Find-Cameras.ps1'; 'NetCheck' = 'NetCheck.ps1' }
$src = @{}; foreach ($t in @($need.Keys)) { $src[$t] = Get-TkInstallSource $here $t }
$optional = @('config.json', 'version.json')   # version.json: a copy of the repository has it one folder up (the release manifest)
$missing = @($files | Where-Object { $optional -notcontains $_ -and -not (Test-Path -LiteralPath (Join-Path $here $_)) })
if (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $here 'modules') 'NvrHealth') 'NvrHealth.psm1'))) { $missing += 'modules\NvrHealth\NvrHealth.psm1' }
foreach ($t in @($need.Keys)) { if (-not (Test-Path -LiteralPath (Join-Path $Root (Join-Path $t $need[$t])))) { if (-not $src[$t] -or -not (Test-Path -LiteralPath (Join-Path $src[$t] $need[$t]))) { $missing += ($t + '\' + $need[$t]) } } }
if ($PlanOnly) { [ordered]@{ toolkitFrom = $here; tools = $src; missing = @($missing) } | ConvertTo-Json -Depth 3; exit $(if ($missing.Count) { 3 } else { 0 }) }
if ($missing.Count) { 'INSTALL STOPPED - nothing was changed. These files are missing from what you are installing from: ' + ($missing -join ', ') + '. Copy the whole WireIt Toolkit folder (with FixNVR, CamReset and NetCheck beside it, or in .\bundle) and run this again.'; exit 3 }
New-Item -ItemType Directory -Force -Path $tk, (Join-Path $tk 'logs'), (Join-Path $tk 'previous') | Out-Null
if ((Resolve-Path $here).Path.TrimEnd('\') -ne (Resolve-Path $tk).Path.TrimEnd('\')) {
  foreach ($f in $files) { if (Test-Path (Join-Path $here $f)) { Copy-Item (Join-Path $here $f) (Join-Path $tk $f) -Force } }
  foreach ($d in 'tests', 'modules') { if (Test-Path (Join-Path $here $d)) { Copy-Item (Join-Path $here $d) $tk -Recurse -Force } }
  if (-not (Test-Path (Join-Path $tk 'config.json')) -and (Test-Path (Join-Path $here 'config.json'))) { Copy-Item (Join-Path $here 'config.json') (Join-Path $tk 'config.json') }
}
# bundled tool folders (only when they came along); config.json of an existing tool is never replaced
foreach ($t in 'NetCheck', 'FixNVR', 'CamReset') {
  $from = $src[$t]
  if ($from) {
    $dst = Join-Path $Root $t; New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem $from -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($from.Length).TrimStart('\', '/'); $to = Join-Path $dst $rel
      if ($_.Name -ieq 'config.json' -and (Test-Path $to)) { return }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null; Copy-Item $_.FullName $to -Force
    }
    "Copied $t to $dst"
  }
}
$notThere = @($files | Where-Object { $optional -notcontains $_ -and -not (Test-Path -LiteralPath (Join-Path $tk $_)) })
if ($notThere.Count) { 'INSTALL NOT COMPLETE: these files did not get into ' + $tk + ': ' + ($notThere -join ', '); exit 4 }
Get-ChildItem $Root -Recurse -Include *.ps1, *.cmd -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
if (-not $NoShortcut) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $sh = New-Object -ComObject WScript.Shell
  # 2.2.1 (review M3): run as an admin, the shortcut goes on EVERY user's desktop and Start menu (the Crew login too), not just the admin's
  $isAdm0 = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $targets = $(if ($isAdm0) { @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms')) } else { @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) '')) })
  foreach ($d in $targets) {
    if (-not $d -or -not (Test-Path $d)) { continue }
    $lnk = $sh.CreateShortcut((Join-Path $d 'WireIt Toolkit.lnk'))
    $lnk.TargetPath = $ps
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $tk 'WireItToolkit.ps1') + '"'
    $lnk.WorkingDirectory = $tk; $lnk.WindowStyle = 7; $lnk.Description = 'WireIt Toolkit - find cameras, fix NVRs, reset passwords'
    $lnk.IconLocation = (Join-Path $tk 'wireit.ico') + ',0'
    $lnk.Save(); 'Shortcut: ' + (Join-Path $d 'WireIt Toolkit.lnk')
  }
}
$adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# camera discovery firewall rules (Nov 3 2026): so "1 Find cameras" never pops a Windows Firewall question on a tech
$cr = Join-Path $Root 'CamReset\Install-CamReset.ps1'
$fwName = 'WireIt CamReset - camera discovery replies (PowerShell, local network)'
if (-not (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue)) {
  if (-not $adm) { 'Run this again as administrator to add the camera-discovery firewall rules (then Windows never asks about the firewall on Find cameras).' }
  elseif (Test-Path $cr) { & $cr -FirewallOnly }
  else {
    New-NetFirewallRule -DisplayName 'WireIt CamReset - SADP discovery replies (UDP 37020)' -Direction Inbound -Protocol UDP -LocalPort 37020 -Action Allow -Profile Any | Out-Null
    foreach ($p in @((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'))) {
      if (Test-Path $p) { New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Program $p -Protocol UDP -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null }
    }
    'Added the camera-discovery firewall rules.'
  }
}
# HiTools Delivery can be in either Program Files folder (the Office PC has the 64-bit one): look in both
$hitPaths = @((Join-Path ${env:ProgramFiles(x86)} 'HiToolsDelivery\client\HiToolsDelivery.exe'), (Join-Path $env:ProgramFiles 'HiToolsDelivery\client\HiToolsDelivery.exe'), 'C:\Program Files (x86)\HiToolsDelivery\client\HiToolsDelivery.exe', 'C:\Program Files\HiToolsDelivery\client\HiToolsDelivery.exe') | Where-Object { $_ } | Select-Object -Unique
if (-not @($hitPaths | Where-Object { Test-Path $_ }).Count) { 'NOTE: HiTools Delivery (Hikvision''s free tool) is not installed. Button 4 needs it: hikvision.com > Support > Tools > HiTools Delivery.' }
foreach ($t in 'FixNVR\FixNVR.ps1', 'CamReset\Find-Cameras.ps1', 'NetCheck\NetCheck.ps1') { if (-not (Test-Path (Join-Path $Root $t))) { 'MISSING: ' + (Join-Path $Root $t) + ' (copy the whole C:\WireIt folder from the old PC)' } }
# ---------------- 2.2.0: permissions, the Fix this site task, the password vault (admin only) ----------------
$acl = Join-Path $tk 'WireItAcl.ps1'
if (Test-Path $acl) {
  . $acl
  if (-not $adm) { 'NOT LOCKED: run this installer as administrator once (the Toolkit folder is still writable by the Crew login, and Fix this site cannot run without an admin password).' }
  else {
    # 1) move 2.1's saved site passwords (encrypted for the admin who typed them) into vault\ as machine-wide, before the folder is locked
    $fsd = Join-Path $tk 'FixSiteDevices.ps1'
    if (Test-Path $fsd) {
      try {
        . $fsd
        $cv = Convert-FsSecretStores (Join-Path $tk 'secrets') (Join-Path $tk 'vault')
        if ($cv.moved) { 'Moved ' + $cv.moved + ' saved site password file(s) into the machine-wide vault.' }
        if (@($cv.unreadable).Count) { 'WARNING: ' + @($cv.unreadable).Count + ' saved password file(s) were made by another Windows account and cannot be read here: ' + (@($cv.unreadable) -join ', ') + '. Run this installer as that account, or type those sites'' passwords again (Site password... > T; they are in Bitwarden).' }
      } catch { 'Could not move the saved site passwords: ' + $_.Exception.Message }
    }
    # 1b) 2.2.1 (review M2): remembered NVR logins (CamViews) leave the Crew-readable secrets\ for vault\ (Administrators + SYSTEM only)
    foreach ($nf in @(Get-ChildItem -LiteralPath (Join-Path $tk 'secrets') -Filter 'nvr-*.bin' -File -ErrorAction SilentlyContinue)) {
      try { New-Item -ItemType Directory -Force -Path (Join-Path $tk 'vault') | Out-Null; $to = Join-Path (Join-Path $tk 'vault') $nf.Name; Move-Item -LiteralPath $nf.FullName -Destination $to -Force; $null = & icacls.exe $to /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1; 'Moved the remembered NVR login ' + $nf.Name + ' into the vault.' } catch { 'Could not move ' + $nf.Name + ': ' + $_.Exception.Message }
    }
    # 2) the site-password word that 2.1 wrote in clear text to the run logs
    $wn = Clear-WordAnswerFromLogs @((Join-Path $tk 'runs'), (Join-Path $tk 'fixsite-runs'), (Join-Path $Root 'FixNVR\runs'))
    if ($wn) { 'Blanked the site-password word in ' + $wn + ' old log file(s).' }
    # 3) lock the folders
    $ar = Invoke-WireItAclPlan $Root
    if ($ar.ok) { 'Locked ' + $Root + ': Administrators + SYSTEM full control, the Crew login read + execute only (plus its own logs, state and inbox folders).' } else { 'PERMISSIONS NOT FULLY SET: ' + (@($ar.failed) -join '; ') }
    # 4) the admin-owned task the Crew login starts
    $rt = Register-WireItRunnerTask $tk
    if ($rt.ok) { 'Made the "Fix this site" task (runs as SYSTEM; the Crew login can start it, nobody but an admin can change it).' } else { 'FIX THIS SITE TASK NOT SET UP: ' + $rt.why }
  }
}
'WireIt Toolkit installed in ' + $tk
