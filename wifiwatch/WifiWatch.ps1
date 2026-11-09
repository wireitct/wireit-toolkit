# WifiWatch.ps1 - WireIt. Runs as SYSTEM every minute (task "WireIt WifiWatch").
# If Wi-Fi says connected but there is no internet for 2 checks in a row (2 min): netsh wlan disconnect + connect.
# Still no internet 1 min later: disable + enable the Wi-Fi adapter. Then again every 10 min while it stays down.
# Does nothing while a wired Ethernet connection is up. Log: C:\WireIt\WifiWatch\wifiwatch.log (rotates at 200 KB).
# 2.2.11 (Nov 8 2026, Sitebox 2: its 1:56 PM cycle LEFT THE WI-FI ADAPTER DISABLED and then logged "no Wi-Fi adapter" forever):
#   - the off/on cycle is in try/finally: the adapter is ALWAYS switched back on, and checked on (3 tries)
#   - a marker file is written BEFORE the adapter goes off and removed only when it is checked on again; if this run is killed in
#     between (the task's 2-minute limit, a restart), the next run switches the adapter back on first, before anything else
#   - Restore Network (Toolkit) pauses this task while it works and switches it back on at the end
param([string]$Dir = 'C:\WireIt\WifiWatch')
$ErrorActionPreference = 'SilentlyContinue'
$log    = Join-Path $Dir 'wifiwatch.log'
$state  = Join-Path $Dir 'state.txt'
$marker = Join-Path $Dir 'adapter-off.txt'
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
    'sleep'   { Start-Sleep -Seconds ([int]$a.s); return $true }
  }
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
  try { [void](Ww-Op 'connect' @{ name = $iface; prof = $prof }) } catch {}
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
if ($fails -eq 2) {
  L ('reconnecting: netsh wlan disconnect + connect "' + $prof + '"')
  netsh wlan disconnect interface="$iface" | Out-Null
  Start-Sleep -Seconds 4
  netsh wlan connect name="$prof" interface="$iface" | Out-Null
} elseif ($fails -eq 3 -or ($fails -gt 3 -and ($fails % 10) -eq 3)) {
  Invoke-WwAdapterCycle $iface $prof
}
exit 0
