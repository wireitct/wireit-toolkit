# WifiWatch.ps1 - WireIt. Runs as SYSTEM every minute (task "WireIt WifiWatch").
# If Wi-Fi says connected but there is no internet for 2 checks in a row (2 min): netsh wlan disconnect + connect.
# Still no internet 1 min later: disable + enable the Wi-Fi adapter. Then again every 10 min while it stays down.
# Does nothing while a wired Ethernet connection is up. Log: C:\WireIt\WifiWatch\wifiwatch.log (rotates at 200 KB).
# 2.2.11 (Nov 8 2026, Sitebox 2: its 1:56 PM cycle LEFT THE WI-FI ADAPTER DISABLED and then logged "no Wi-Fi adapter" forever):
#   - the off/on cycle is in try/finally: the adapter is ALWAYS switched back on, and checked on (3 tries)
#   - a marker file is written BEFORE the adapter goes off and removed only when it is checked on again; if this run is killed in
#     between (the task's 2-minute limit, a restart), the next run switches the adapter back on first, before anything else
#   - Restore Network (Toolkit) pauses this task while it works (2.2.13: only with the pause file below; it never switches the task off)
# 2.2.12 (Nov 9 2026, Codex P1-7): switching the task off does not stop a copy that is ALREADY running. Restore Network now also writes
#   a pause file (%ProgramData%\WireIt\wifiwatch.pause, line 1 "until=<UTC time>"). While it is fresh this script does nothing
#   (it checks it at the start and again right before every reconnect / adapter off / connect step); switching an adapter back ON
#   that an earlier run left off still happens (that is recovery). An expired pause file (or one more than 30 min ahead) is ignored,
#   so a Restore Network that crashed never stops the watcher for good.
param([string]$Dir = 'C:\WireIt\WifiWatch', [string]$PauseFile = '')
$ErrorActionPreference = 'SilentlyContinue'
$log    = Join-Path $Dir 'wifiwatch.log'
$state  = Join-Path $Dir 'state.txt'
$marker = Join-Path $Dir 'adapter-off.txt'
if (-not $PauseFile) { $pd = $env:ProgramData; if (-not $pd) { $pd = 'C:\ProgramData' }; $PauseFile = Join-Path (Join-Path $pd 'WireIt') 'wifiwatch.pause' }
if ($null -eq $script:WwOps) { $script:WwOps = $null }   # tests put a simulated Windows here
function L($t) {
  if ((Test-Path $log) -and (Get-Item $log).Length -gt 200KB) { Move-Item $log ($log + '.old') -Force }
  Add-Content -Path $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $t)
}
function Ww-Op([string]$op, $a = @{}) {
  if ($script:WwOps) { return (& $script:WwOps $op $a) }
  switch ($op) {
    'disable' { Disable-NetAdapter -Name $a.name -Confirm:$false -ErrorAction Stop; return $true }
    'enable'  { Enable-NetAdapter -Name $a.name -Confirm:$false -ErrorAction Stop; return $true }
    'isup'    { $n = Get-NetAdapter -Name $a.name -ErrorAction SilentlyContinue; return ($n -and [string]$n.Status -ne 'Disabled') }
    'connect' { netsh wlan connect name="$($a.prof)" interface="$($a.name)" | Out-Null; return $true }
    'disconnect' { netsh wlan disconnect interface="$($a.name)" | Out-Null; return $true }
    'sleep'   { Start-Sleep -Seconds ([int]$a.s); return $true }
  }
}
# 2.2.12 (Codex P1-7): $true while Restore Network's pause file is fresh (until= in the future, at most 30 min ahead)
function Test-WwPaused {
  if (-not (Test-Path -LiteralPath $PauseFile)) { return $false }
  $t = ''; try { $t = [string](Get-Content -LiteralPath $PauseFile -Raw -ErrorAction Stop) } catch { return $false }
  $m = [regex]::Match($t, '(?m)^until=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\s*$')
  if (-not $m.Success) { L 'pause file unreadable - ignored'; return $false }
  $u = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$u)) { L 'pause file unreadable - ignored'; return $false }
  $now = (Get-Date).ToUniversalTime()
  if ($u -le $now) { L ('pause file expired (' + $m.Groups[1].Value + ') - ignored'); return $false }
  if ($u -gt $now.AddMinutes(30)) { L ('pause file too far ahead (' + $m.Groups[1].Value + ') - ignored'); return $false }
  $script:WwPausedUntil = $m.Groups[1].Value
  return $true
}
# switches the adapter back on and checks it; returns $true when it is on
function Enable-WwAdapter([string]$name) {
  for ($i = 1; $i -le 3; $i++) {
    try { [void](Ww-Op 'enable' @{ name = $name }) } catch { L ('enable try ' + $i + ' failed: ' + $_.Exception.Message) }
    [void](Ww-Op 'sleep' @{ s = 3 })
    if (Ww-Op 'isup' @{ name = $name }) { return $true }
  }
  return $false
}
# a run that was stopped half-way left the adapter off: switch it back on before anything else
function Repair-WwAdapter {
  if (-not (Test-Path -LiteralPath $marker)) { return }
  $name = ([string](Get-Content -LiteralPath $marker -Raw)).Trim()
  if (-not $name) { Remove-Item -LiteralPath $marker -Force; return }
  L ('adapter "' + $name + '" was left switched off by an earlier run - switching it back on')
  if (Enable-WwAdapter $name) { Remove-Item -LiteralPath $marker -Force; L ('adapter "' + $name + '" is on again') } else { L ('adapter "' + $name + '" is STILL OFF - will try again next minute') }
}
function Invoke-WwAdapterCycle([string]$iface, [string]$prof) {
  if (Test-WwPaused) { L ('paused by Restore Network until ' + $script:WwPausedUntil + ' - adapter "' + $iface + '" NOT switched off'); return }
  L ('still no internet: disabling + enabling adapter "' + $iface + '"')
  Set-Content -LiteralPath $marker -Value $iface   # written BEFORE the adapter goes off
  try {
    [void](Ww-Op 'disable' @{ name = $iface })
    [void](Ww-Op 'sleep' @{ s = 6 })
  } catch { L ('disable failed: ' + $_.Exception.Message) }
  finally {
    if (Enable-WwAdapter $iface) { Remove-Item -LiteralPath $marker -Force; L ('adapter "' + $iface + '" is on again') }
    else { L ('adapter "' + $iface + '" did NOT come back on - next run tries again') }
  }
  [void](Ww-Op 'sleep' @{ s = 12 })
  if (Test-WwPaused) { L ('paused by Restore Network until ' + $script:WwPausedUntil + ' - no connect'); return }
  try { [void](Ww-Op 'connect' @{ name = $iface; prof = $prof }) } catch {}
}
# what one failed check does (2 = reconnect, 3 and every 10 after = adapter off/on); nothing while Restore Network's pause is fresh
function Invoke-WwStep([int]$fails, [string]$iface, [string]$prof) {
  if ($fails -eq 2) {
    if (Test-WwPaused) { L ('paused by Restore Network until ' + $script:WwPausedUntil + ' - no reconnect'); return 'paused' }
    L ('reconnecting: netsh wlan disconnect + connect "' + $prof + '"')
    try { [void](Ww-Op 'disconnect' @{ name = $iface }) } catch {}
    [void](Ww-Op 'sleep' @{ s = 4 })
    if (Test-WwPaused) { L ('paused by Restore Network until ' + $script:WwPausedUntil + ' - no connect'); return 'paused' }
    try { [void](Ww-Op 'connect' @{ name = $iface; prof = $prof }) } catch {}
    return 'reconnect'
  } elseif ($fails -eq 3 -or ($fails -gt 3 -and ($fails % 10) -eq 3)) {
    if (Test-WwPaused) { L ('paused by Restore Network until ' + $script:WwPausedUntil + ' - adapter "' + $iface + '" NOT switched off'); return 'paused' }
    Invoke-WwAdapterCycle $iface $prof
    return 'cycle'
  }
  return 'count'
}
function Online {
  $p = New-Object System.Net.NetworkInformation.Ping
  foreach ($ip in '1.1.1.1', '8.8.8.8') { try { if ($p.Send($ip, 1500).Status -eq 'Success') { return 'ping ' + $ip } } catch {} }
  try { $d = Resolve-DnsName -Name 'www.msftconnecttest.com' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop } catch { $d = $null }
  if ($d) {
    try { $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 6; if ($r.Content -like 'Microsoft Connect Test*') { return 'http' } } catch {}
  }
  return $null
}
if ($MyInvocation.InvocationName -eq '.') { return }
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Repair-WwAdapter
# 2.2.12 (Codex P1-7): Restore Network is working on the network - do nothing, count nothing
if (Test-WwPaused) { L ('paused by Restore Network until ' + $script:WwPausedUntil + ' - doing nothing'); exit 0 }
$fails = 0; if (Test-Path $state) { $fails = [int](Get-Content $state -Raw) }
# wired Ethernet up with a gateway -> not our business
$eth = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Bluetooth' }
foreach ($e in $eth) {
  if (Get-NetRoute -InterfaceIndex $e.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue) { if ($fails) { Set-Content $state 0 }; L ('ok (on Ethernet ' + $e.Name + ', not watching Wi-Fi)'); exit 0 }
}
$txt = (netsh wlan show interfaces) -join "`n"
$iface = if ($txt -match '(?m)^\s*Name\s*:\s*(.+?)\s*$') { $Matches[1] } else { $null }
$st    = if ($txt -match '(?m)^\s*State\s*:\s*(.+?)\s*$') { $Matches[1] } else { '' }
$prof  = if ($txt -match '(?m)^\s*Profile\s*:\s*(.+?)\s*$') { $Matches[1] } else { $null }
if (-not $iface) { L 'no Wi-Fi adapter'; exit 0 }
if ($st -ne 'connected' -or -not $prof) { if ($fails) { Set-Content $state 0 }; L ('Wi-Fi not connected (' + $st + '), nothing to do'); exit 0 }
$how = Online
if ($how) {
  if ($fails -ge 2) { L ('ok again after ' + $fails + ' failed checks (' + $how + ')') } else { L ('ok (' + $prof + ', ' + $how + ')') }
  Set-Content $state 0; exit 0
}
$fails++; Set-Content $state $fails
L ('NO INTERNET on Wi-Fi "' + $prof + '" (check ' + $fails + ')')
[void](Invoke-WwStep $fails $iface $prof)
exit 0
