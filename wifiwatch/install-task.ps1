# install-task.ps1 - WireIt WifiWatch (Wi-Fi auto-reconnect). Site boxes only. Safe to run again.
# Task "WireIt WifiWatch": SYSTEM, at startup and every 1 minute. Does nothing while wired Ethernet is up.
# 2.2.20 (Codex 2.2.19 R20, class A): "Installed" is printed only after Windows took the task (a failed registration now STOPS the
# script, it no longer runs on to the success line) AND the task reads back as it should be: it exists, runs WifiWatch.ps1 with
# powershell.exe as SYSTEM, has the start-up trigger and the every-1-minute repeat, and its settings (2 min limit, one copy at a time).
# Anything else ends with "NOT INSTALLED: ..." and a non-zero exit code.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1  = Join-Path $here 'WifiWatch.ps1'
$wwTaskName = 'WireIt WifiWatch'
# '' = the task read back from Windows is the one this script installs, else what is wrong (plain words)
function Get-WwTaskProblem($task, [string]$ps1) {
  if (-not $task) { return 'the task is not there' }
  $acts = @($task.Actions | Where-Object { $_ })
  if ($acts.Count -ne 1) { return ('it has ' + $acts.Count + ' actions, not 1') }
  if ([string]$acts[0].Execute -notmatch '(?i)(^|\\)powershell(\.exe)?$') { return 'it does not run powershell.exe' }
  if ([string]$acts[0].Arguments -notlike ('*"' + $ps1 + '"*')) { return 'it does not run this WifiWatch.ps1' }
  $trs = @($task.Triggers | Where-Object { $_ })
  $boot = @($trs | Where-Object { $cn = ''; try { $cn = [string]$_.CimClass.CimClassName } catch {}; $cn -eq 'MSFT_TaskBootTrigger' })
  $rep = @($trs | Where-Object { $_.Repetition -and [string]$_.Repetition.Interval -eq 'PT1M' })
  if (-not $boot.Count) { return 'it has no start-up trigger' }
  if (-not $rep.Count) { return 'it does not repeat every minute' }
  $pr = $task.Principal
  if (-not $pr -or [string]$pr.UserId -notmatch '(?i)^(NT AUTHORITY\\)?SYSTEM$') { return 'it does not run as SYSTEM' }
  if ([string]$pr.RunLevel -ne 'Highest') { return 'it does not run with the highest rights' }
  $st = $task.Settings
  if (-not $st) { return 'its settings could not be read' }
  if ([string]$st.ExecutionTimeLimit -ne 'PT2M') { return 'its time limit is not 2 minutes' }
  if ([string]$st.MultipleInstances -ne 'IgnoreNew') { return 'it may start a second copy while one runs' }
  if ($st.PSObject.Properties['Enabled'] -and $st.Enabled -eq $false) { return 'it is turned off' }
  return ''
}
if ($MyInvocation.InvocationName -eq '.' -and $env:WIREIT_WW_TEST_FUNCTIONS_ONLY) { return }
try {
  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"')
  $t1 = New-ScheduledTaskTrigger -AtStartup
  $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
  $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $wwTaskName -Description 'WireIt: Wi-Fi auto-reconnect. Connected but no internet for 2 min -> reconnect; then adapter reset. Does nothing on Ethernet. Log C:\WireIt\WifiWatch\wifiwatch.log' -Action $a -Trigger @($t1, $t2) -Settings $s -User 'SYSTEM' -RunLevel Highest -Force -ErrorAction Stop | Out-Null
} catch {
  throw ('NOT INSTALLED: WireIt WifiWatch - Windows did not take the task (' + $_.Exception.Message + '). Run this again as an admin.')
}
$wwTask = $null; $wwReadErr = ''
try { $wwTask = Get-ScheduledTask -TaskName $wwTaskName -ErrorAction Stop } catch { $wwReadErr = $_.Exception.Message }
$wwWhy = $(if ($wwReadErr) { 'the task could not be read back (' + $wwReadErr + ')' } else { Get-WwTaskProblem $wwTask $ps1 })
if ($wwWhy) { throw ('NOT INSTALLED: WireIt WifiWatch - ' + $wwWhy + '. Run this again as an admin.') }
"Installed: WireIt WifiWatch (every minute, does nothing on Ethernet) - checked: the task is there, runs WifiWatch.ps1 as SYSTEM at start-up and every minute"
