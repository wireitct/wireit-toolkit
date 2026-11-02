<#
 Install-CamReset.ps1 - one-time setup on a Windows PC (run as admin). Safe to run again.
 - Firewall: lets Hikvision discovery answers in (UDP 37020) and lets HiTools Delivery receive them,
   so neither this tool nor HiTools pops a "Windows Defender Firewall has blocked..." window on a site network.
 - Makes the out/, replies/, requests/, state/ folders.
 Remove: .\Install-CamReset.ps1 -Uninstall
#>
param([switch]$Uninstall)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$names = 'WireIt CamReset - SADP discovery replies (UDP 37020)', 'WireIt CamReset - HiTools Delivery', 'WireIt CamReset - HiTools hscan'
foreach ($n in $names) { Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
if ($Uninstall) { 'Firewall rules removed.'; exit 0 }
New-NetFirewallRule -DisplayName $names[0] -Direction Inbound -Protocol UDP -LocalPort 37020 -Action Allow -Profile Any | Out-Null
$hit = 'C:\Program Files (x86)\HiToolsDelivery\client'
if (Test-Path "$hit\HiToolsDelivery.exe") { New-NetFirewallRule -DisplayName $names[1] -Direction Inbound -Program "$hit\HiToolsDelivery.exe" -Action Allow -Profile Any | Out-Null }
if (Test-Path "$hit\hscan\hscan.exe") { New-NetFirewallRule -DisplayName $names[2] -Direction Inbound -Program "$hit\hscan\hscan.exe" -Action Allow -Profile Any | Out-Null }
foreach ($d in 'out', 'replies', 'requests', 'state') { New-Item -ItemType Directory -Force -Path (Join-Path $here $d) | Out-Null }
'Installed. Rules: ' + ((Get-NetFirewallRule -DisplayName 'WireIt CamReset*' | Select-Object -ExpandProperty DisplayName) -join '; ')
