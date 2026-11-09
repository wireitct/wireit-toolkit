# install-task.ps1 - WireIt WifiWatch (Wi-Fi auto-reconnect). Site boxes only. Safe to run again.
# Task "WireIt WifiWatch": SYSTEM, at startup and every 1 minute. Does nothing while wired Ethernet is up.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1  = Join-Path $here 'WifiWatch.ps1'
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"')
$t1 = New-ScheduledTaskTrigger -AtStartup
$t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'WireIt WifiWatch' -Description 'WireIt: Wi-Fi auto-reconnect. Connected but no internet for 2 min -> reconnect; then adapter reset. Does nothing on Ethernet. Log C:\WireIt\WifiWatch\wifiwatch.log' -Action $a -Trigger @($t1, $t2) -Settings $s -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
"Installed: WireIt WifiWatch (every minute, does nothing on Ethernet)"
