<#
 Install-Toolkit.ps1 - puts the WireIt Toolkit on this PC (Windows PowerShell 5.1). Safe to run again.
 Run as administrator from the Toolkit folder:  powershell -ExecutionPolicy Bypass -File .\Install-Toolkit.ps1
 - makes C:\WireIt\Toolkit (logs\, previous\) and copies itself there if run from somewhere else (USB stick, Downloads)
 - copies NetCheck into C:\WireIt\NetCheck if it came along in .\bundle\NetCheck
 - desktop shortcut "WireIt Toolkit" (+ Start menu) with the WireIt icon
 - CamReset firewall rules (Hikvision discovery replies) if CamReset is here and they are missing
 Nothing is downloaded and no password is asked or stored.
#>
param([string]$Root = 'C:\WireIt', [switch]$NoShortcut)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tk = Join-Path $Root 'Toolkit'
New-Item -ItemType Directory -Force -Path $tk, (Join-Path $tk 'logs'), (Join-Path $tk 'previous') | Out-Null
$files = 'WireItToolkit.ps1', 'ToolkitCore.ps1', 'WireIt Toolkit.cmd', 'Install-Toolkit.ps1', 'README.txt', 'wireit.ico', 'wireit-logo.png', 'version.json'
if ((Resolve-Path $here).Path.TrimEnd('\') -ne (Resolve-Path $tk).Path.TrimEnd('\')) {
  foreach ($f in $files) { if (Test-Path (Join-Path $here $f)) { Copy-Item (Join-Path $here $f) (Join-Path $tk $f) -Force } }
  if (Test-Path (Join-Path $here 'tests')) { Copy-Item (Join-Path $here 'tests') $tk -Recurse -Force }
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
$cr = Join-Path $Root 'CamReset\Install-CamReset.ps1'
if ((Test-Path $cr) -and -not (Get-NetFirewallRule -DisplayName 'WireIt CamReset*' -ErrorAction SilentlyContinue)) {
  if ($adm) { & $cr } else { 'Run this again as administrator to add the camera-discovery firewall rules.' }
}
$h = 'C:\Program Files (x86)\HiToolsDelivery\client\HiToolsDelivery.exe'
if (-not (Test-Path $h)) { 'NOTE: HiTools Delivery (Hikvision''s free tool) is not installed. Button 4 needs it: hikvision.com > Support > Tools > HiTools Delivery.' }
foreach ($t in 'FixNVR\FixNVR.ps1', 'CamReset\Find-Cameras.ps1', 'NetCheck\NetCheck.ps1') { if (-not (Test-Path (Join-Path $Root $t))) { 'MISSING: ' + (Join-Path $Root $t) + ' (copy the whole C:\WireIt folder from the old PC)' } }
'WireIt Toolkit installed in ' + $tk
