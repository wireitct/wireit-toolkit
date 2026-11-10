<#
 Install-Toolkit.ps1 - puts the WireIt Toolkit on this PC (Windows PowerShell 5.1). Safe to run again.
 Run as administrator from the Toolkit folder:  powershell -ExecutionPolicy Bypass -File .\Install-Toolkit.ps1
 - makes C:\WireIt\Toolkit (logs\, previous\) and copies itself there if run from somewhere else (USB stick, Downloads)
 - copies NetCheck into C:\WireIt\NetCheck if it came along in .\bundle\NetCheck
 - desktop shortcut "WireIt Toolkit" (+ Start menu) with the WireIt icon
 - (2.2.3) no SYSTEM task and no folder lock any more (2.2.3 ASSUMED Crew is a local admin; 2.2.16: it is NOT - Crew is a standard
   user, see the NOTE this installer prints; install behaviour unchanged). Run as admin, it removes 2.2.x's "Fix this
   site" task and folder lock (back to Windows' normal permissions) and the files only that design used, moves 2.1's saved site
   passwords into vault\, and blanks the site-password word that 2.1 logged. Safe to run again.
 - camera-discovery firewall rules (UDP answers to PowerShell from the local network + SADP 37020) when run as admin and missing
 Nothing is downloaded and no password is asked or stored.
#>
param([string]$Root = 'C:\WireIt', [switch]$NoShortcut, [switch]$PlanOnly)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tk = Join-Path $Root 'Toolkit'
$files = 'WireItToolkit.ps1', 'ToolkitCore.ps1', 'WireIt Toolkit.cmd', 'Install-Toolkit.ps1', 'README.txt', 'wireit.ico', 'wireit-logo.png', 'version.json', 'CamViews.ps1', 'Set upload key.cmd', 'NvrCheck.ps1', 'ScanUpload.ps1', 'FixIt.ps1', 'FixSite.ps1', 'FixSiteCore.ps1', 'FixSiteDevices.ps1', 'FixSiteWindow.ps1', 'HikSadp.ps1', 'HikPortal.ps1', 'HikMail.ps1', 'HikReset.ps1', 'HikResetFlow.ps1', 'HikEmailDrop.ps1', 'FixSiteBw.ps1', 'ToolkitMigrate.ps1', 'ToolkitRecover.ps1', 'RestoreNetwork.ps1', 'Restore Network.cmd'   # 2.2.11: Restore Network
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
# 2.2.2 (re-review M3 / NEW-2): a copy of the repository has the version file one folder up (the release manifest): it is installed
# too, so the Toolkit knows its own version (2.2.1 read 0.0.0 and the first start "updated" it back to 2.0.4)
$rootVj = Join-Path (Split-Path -Parent $here) 'version.json'
if (-not (Test-Path -LiteralPath (Join-Path $here 'version.json')) -and (Test-Path -LiteralPath $rootVj)) {
  try { $mv = Get-Content -LiteralPath $rootVj -Raw | ConvertFrom-Json; ([ordered]@{ version = [string]$mv.version; released = [string]$mv.released; commit = [string]$mv.commit; installed = (Get-Date -Format 's'); from = 'repository copy' } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $tk 'version.json') -Encoding UTF8; 'Version ' + $mv.version + ' (from the repository''s version.json)' } catch { 'Could not read ' + $rootVj + ': ' + $_.Exception.Message }
}
# bundled tool folders (only when they came along); config.json of an existing tool is never replaced
foreach ($t in 'NetCheck', 'FixNVR', 'CamReset') {
  $from = $src[$t]
  $dst = Join-Path $Root $t
  # 2.2.2 (Codex M3): run again from C:\WireIt\Toolkit, the "companion" folder IS the installed one: never copy a folder onto itself
  if ($from -and (Test-Path -LiteralPath $dst) -and ((Resolve-Path -LiteralPath $from).Path.TrimEnd('\', '/') -eq (Resolve-Path -LiteralPath $dst).Path.TrimEnd('\', '/'))) { "$t is already in place ($dst)"; $from = '' }
  if ($from) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
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
    # 2.2.11: "Restore Network" on its own (this PC's network back to normal), one double-click, works without the Toolkit window
    $l2 = $sh.CreateShortcut((Join-Path $d 'Restore Network.lnk'))
    $l2.TargetPath = (Join-Path $tk 'Restore Network.cmd'); $l2.WorkingDirectory = $tk; $l2.Description = 'WireIt: this PC''s network back to normal (DHCP, extra addresses off)'
    $l2.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',18'
    $l2.Save(); 'Shortcut: ' + (Join-Path $d 'Restore Network.lnk')
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
# ---------------- 2.2.3: no SYSTEM task, no folder lock (2.2.3 assumed Crew is a local admin - it is a standard user, see below) ----------------
# 2.2.16 (Codex 2.2.15 review): the Crew login is a STANDARD user. The elevated tools (Fix this site's blue window, Fix NVR, Restore
# Network) are started with RunAs, so on a Crew login Windows asks for an administrator's name and password and they run as that admin
# account (its DPAPI saved passwords, its profile), not as Crew. Install behaviour is NOT changed here; the note below says so, and the
# real standard-Crew-login test is DEFERRED.
'NOTE (2.2.16): the Crew login is a standard Windows user. Fix this site / Fix NVR / Restore Network ask Windows for an ADMINISTRATOR name and password there and then run as that administrator. Test once on the real Crew login before handing the PC over.'
if (-not $adm) { 'NOTE: run this installer as administrator once to remove 2.2.x''s "Fix this site" task and folder lock if this PC had them.' }
else {
  # 1)-2) 2.2.4: the SYSTEM task, the IPC folder, the old files and the old folder lock come off (logged); vault\ and secrets\ stay
  # locked to Administrators + SYSTEM + you, and each local admin user can read the upload key without elevation (#26). See ToolkitMigrate.ps1.
  # (2.2.16: a STANDARD Crew login is not a local admin user, so that #26 sentence does not cover Crew - UNVERIFIED, DEFERRED)
  try {
    . (Join-Path $tk 'ToolkitMigrate.ps1')
    $mr = Invoke-TkMigration -Root $Root -ToolkitDir $tk -OwnerSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    foreach ($l in @($mr.log)) { $l }; foreach ($w in @($mr.warnings)) { 'WARNING: ' + $w }
    try { Add-Content -LiteralPath (Join-Path (Join-Path $tk 'logs') 'install.log') -Value (@((Get-Date -Format s) + ' migration') + @($mr.log) + @($mr.warnings | ForEach-Object { 'WARNING: ' + $_ })) } catch {}
  } catch { 'WARNING: the 2.2.x clean-up did not run: ' + $_.Exception.Message }
  # 3) 2.1's saved site passwords (encrypted for the admin who typed them) and the remembered NVR logins go into vault\
  $fsd = Join-Path $tk 'FixSiteDevices.ps1'
  if (Test-Path $fsd) {
    try {
      . $fsd
      $cv = Convert-FsSecretStores (Join-Path $tk 'secrets') (Join-Path $tk 'vault')
      if ($cv.moved) { 'Moved ' + $cv.moved + ' saved site password file(s) into the machine-wide vault.' }
      if (@($cv.unreadable).Count) { 'WARNING: ' + @($cv.unreadable).Count + ' saved password file(s) were made by another Windows account and cannot be read here: ' + (@($cv.unreadable) -join ', ') + '. Run this installer as that account, or type those sites'' passwords again (Site password... > T; they are in Bitwarden).' }
      foreach ($nf in @(Get-ChildItem -LiteralPath (Join-Path $tk 'secrets') -Filter 'nvr-*.bin' -File -ErrorAction SilentlyContinue)) { try { New-Item -ItemType Directory -Force -Path (Join-Path $tk 'vault') | Out-Null; Move-Item -LiteralPath $nf.FullName -Destination (Join-Path (Join-Path $tk 'vault') $nf.Name) -Force; 'Moved the remembered NVR login ' + $nf.Name + ' into the vault.' } catch { 'Could not move ' + $nf.Name + ': ' + $_.Exception.Message } }
      # 4) the site-password word that 2.1 wrote in clear text to the run logs
      $wn = Clear-WordAnswerFromLogs @((Join-Path $tk 'runs'), (Join-Path $tk 'fixsite-runs'), (Join-Path $Root 'FixNVR\runs'))
      if ($wn) { 'Blanked the site-password word in ' + $wn + ' old log file(s).' }
    } catch { 'Could not move the saved site passwords: ' + $_.Exception.Message }
  }
}
'WireIt Toolkit installed in ' + $tk
