<#
 Install-CamReset.ps1 - one-time setup on a Windows PC (run as admin). Safe to run again.
 - Firewall: lets camera discovery answers in, so neither this tool nor HiTools pops a
   "Windows Defender Firewall has blocked..." window on a site network:
     * Hikvision SADP answers (UDP 37020; any sender, because SADP also finds cameras on another IP scheme)
     * camera discovery answers to PowerShell (UDP, local network only) - the ONVIF answers Find Cameras listens for
     * HiTools Delivery / hscan when HiTools is installed
   The network sweep in Find Cameras needs no rule at all (it only connects out).
 - Makes the out/, replies/, requests/, state/ folders.
 Remove: .\Install-CamReset.ps1 -Uninstall      Firewall rules only: .\Install-CamReset.ps1 -FirewallOnly
#>
param([switch]$Uninstall, [switch]$FirewallOnly)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) { 'Run this as administrator (right-click PowerShell > Run as administrator). Nothing was changed.'; exit 1 }
$names = 'WireIt CamReset - SADP discovery replies (UDP 37020)', 'WireIt CamReset - HiTools Delivery', 'WireIt CamReset - HiTools hscan', 'WireIt CamReset - camera discovery replies (PowerShell, local network)'
foreach ($n in $names) { Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
if ($Uninstall) { 'Firewall rules removed.'; exit 0 }
# every profile: site networks usually come up as "Public" in Windows, and that is where the popup appears
New-NetFirewallRule -DisplayName $names[0] -Direction Inbound -Protocol UDP -LocalPort 37020 -Action Allow -Profile Any | Out-Null
foreach ($ps in @((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'))) {
  if (Test-Path $ps) { New-NetFirewallRule -DisplayName $names[3] -Direction Inbound -Program $ps -Protocol UDP -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null }
}
# HiTools Delivery installs under either Program Files folder (the Office PC has it in the 64-bit one): a rule for every copy found
foreach ($hit in @((Join-Path ${env:ProgramFiles(x86)} 'HiToolsDelivery\client'), (Join-Path $env:ProgramFiles 'HiToolsDelivery\client'), 'C:\Program Files (x86)\HiToolsDelivery\client', 'C:\Program Files\HiToolsDelivery\client') | Where-Object { $_ } | Select-Object -Unique) {
  if (Test-Path "$hit\HiToolsDelivery.exe") { New-NetFirewallRule -DisplayName $names[1] -Direction Inbound -Program "$hit\HiToolsDelivery.exe" -Action Allow -Profile Any | Out-Null }
  if (Test-Path "$hit\hscan\hscan.exe") { New-NetFirewallRule -DisplayName $names[2] -Direction Inbound -Program "$hit\hscan\hscan.exe" -Action Allow -Profile Any | Out-Null }
}
if (-not $FirewallOnly) { foreach ($d in 'out', 'replies', 'requests', 'state') { New-Item -ItemType Directory -Force -Path (Join-Path $here $d) | Out-Null } }
'Installed. Rules: ' + ((Get-NetFirewallRule -DisplayName 'WireIt CamReset*' | Select-Object -ExpandProperty DisplayName | Sort-Object -Unique) -join '; ')
$blk = @(Get-NetFirewallRule -DisplayName 'Windows PowerShell' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Direction -eq 'Inbound' -and [string]$_.Action -eq 'Block' -and [string]$_.Enabled -eq 'True' })
if ($blk.Count) { 'NOTE: Windows also has ' + $blk.Count + ' rule(s) that BLOCK "Windows PowerShell" (someone pressed Cancel on the firewall popup). Block wins over Allow, so camera answers can still be lost. Delete them in Windows Defender Firewall > Advanced settings > Inbound Rules (the red "Windows PowerShell" rules). Not removed automatically.' }
