<#
 Install-Toolkit.ps1 - puts the WireIt Toolkit on this PC (Windows PowerShell 5.1). Safe to run again.
 Run as administrator from the Toolkit folder:  powershell -ExecutionPolicy Bypass -File .\Install-Toolkit.ps1
 - makes C:\WireIt\Toolkit (logs\, previous\) and copies itself there if run from somewhere else (USB stick, Downloads)
 - copies NetCheck into C:\WireIt\NetCheck if it came along in .\bundle\NetCheck
 - desktop shortcut "WireIt Toolkit" (+ Start menu) with the WireIt icon
 - camera-discovery firewall rules (UDP answers to PowerShell from the local network + SADP 37020) when run as admin and missing
 Nothing is downloaded and no password is asked or stored.
#>
param([string]$Root = 'C:\WireIt', [switch]$NoShortcut)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tk = Join-Path $Root 'Toolkit'
New-Item -ItemType Directory -Force -Path $tk, (Join-Path $tk 'logs'), (Join-Path $tk 'previous') | Out-Null
$files = 'WireItToolkit.ps1', 'ToolkitCore.ps1', 'WireIt Toolkit.cmd', 'Install-Toolkit.ps1', 'README.txt', 'wireit.ico', 'wireit-logo.png', 'version.json', 'CamViews.ps1', 'Set upload key.cmd', 'NvrCheck.ps1', 'ScanUpload.ps1', 'FixIt.ps1', 'FixSite.ps1', 'FixSiteCore.ps1', 'FixSiteDevices.ps1', 'FixSiteWindow.ps1', 'HikSadp.ps1', 'HikPortal.ps1', 'HikMail.ps1', 'HikReset.ps1', 'HikResetFlow.ps1'
if ((Resolve-Path $here).Path.TrimEnd('\') -ne (Resolve-Path $tk).Path.TrimEnd('\')) {
  foreach ($f in $files) { if (Test-Path (Join-Path $here $f)) { Copy-Item (Join-Path $here $f) (Join-Path $tk $f) -Force } }
  foreach ($d in 'tests', 'modules') { if (Test-Path (Join-Path $here $d)) { Copy-Item (Join-Path $here $d) $tk -Recurse -Force } }
  if (-not (Test-Path (Join-Path $tk 'config.json')) -and (Test-Path (Join-Path $here 'config.json'))) { Copy-Item (Join-Path $here 'config.json') (Join-Path $tk 'config.json') }
}
# bundled tool folders (only when they came along); config.json of an existing tool is never replaced
foreach ($t in 'NetCheck', 'FixNVR', 'CamReset') {
  $src = Join-Path $here ('bundle\' + $t)
  if (Test-Path $src) {
    $dst = Join-Path $Root $t; New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem $src -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($src.Length).TrimStart('\'); $to = Join-Path $dst $rel
      if ($_.Name -ieq 'config.json' -and (Test-Path $to)) { return }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null; Copy-Item $_.FullName $to -Force
    }
    "Copied $t to $dst"
  }
}
Get-ChildItem $Root -Recurse -Include *.ps1, *.cmd -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
if (-not $NoShortcut) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $sh = New-Object -ComObject WScript.Shell
  $targets = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) ''))
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
'WireIt Toolkit installed in ' + $tk
