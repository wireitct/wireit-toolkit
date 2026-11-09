<#
 RestoreNetwork.ps1 - WireIt Toolkit 2.2.11: "Restore Network". ONE button: this PC's network adapter goes back to normal.
 Moshe Nov 9 2026 (add-on #3): the crew runs it, the laptop ends up as it was; running it twice is fine; a run that could not finish
 says "FAILED - Run again". No Tab and no AI inside; it runs on its own (Toolkit button, "Restore Network.cmd", or this file).

 What it does to the CHOSEN adapter (nothing else is touched):
   1. switches the "WireIt WifiWatch" task off while it works, and ALWAYS back on at the end (try/finally), so WifiWatch cannot
      take the Wi-Fi down half-way through (Nov 8: WifiWatch left Sitebox 2's Wi-Fi adapter disabled)
   2. turns the adapter on if it is disabled
   3. DHCP on (the router gives the address)
   4. takes off every fixed (manual) IPv4 address the Toolkit or a tech put on: BOTH copies, the live one and the saved
      (persistent) one - "netsh interface ipv4 add address" saves it, so a live-only removal comes back after a restart
   5. takes off a fixed default gateway (both copies) and puts DNS back to automatic
   6. DHCP+static coexistence back to off (or to what the Toolkit's own record says it was before)
   7. reconnects (Wi-Fi: its saved network; cable: asks the router for an address) and waits for the address
   8. reads the adapter back and ends with "DONE - network is back to normal" or "FAILED - Run again"
 Windows asks for permission (UAC) only when something really has to change; an adapter that is already normal needs no admin.
 A short receipt of what was changed is saved in Toolkit\receipts\ (plain text).
 Exit codes: 0 done, 2 could not start (nothing changed), 6 FAILED - Run again.
 NEEDS WINDOWS CHECK: the Windows commands (Get/Remove-NetIPAddress, Get/Remove-NetRoute, netsh, Enable-NetAdapter, the task).
#>
param(
  [string]$Adapter = '',            # the adapter's name as Windows shows it ("Ethernet", "Wi-Fi 2"); empty = the one that needs it
  [switch]$List,                    # print the adapters as JSON and stop (the Toolkit window uses it for its pick list)
  [switch]$Auto,                    # no question: take the suggested adapter
  [switch]$Elevated,                # internal: this is the copy Windows started with admin rights
  [string]$OutFile = '',            # internal: the elevated copy writes what it says here (the first copy shows it)
  [string]$ToolkitDir = '',         # where the Toolkit is (default: this file's folder)
  [string]$FixNvrState = '',        # Fix NVR's record of its temporary addresses (default ..\FixNVR\state\temp-ips.json)
  [string]$ReceiptDir = '',         # default <Toolkit>\receipts
  [int]$WaitSeconds = 30,           # how long to wait for the router's address
  [switch]$NoElevate                # tests: never ask Windows for admin rights
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:RnVersion = '2.2.11'
if (-not $ToolkitDir) { $ToolkitDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $FixNvrState) { $FixNvrState = Join-Path (Join-Path (Join-Path (Split-Path -Parent $ToolkitDir) 'FixNVR') 'state') 'temp-ips.json' }
if (-not $ReceiptDir) { $ReceiptDir = Join-Path $ToolkitDir 'receipts' }
$script:RnFixSiteState = Join-Path (Join-Path (Join-Path $ToolkitDir 'fixsite-runs') '_state') 'fixsite-temp-ips.json'
$script:RnWifiWatchTask = 'WireIt WifiWatch'
$script:RnWifiWatchState = 'C:\WireIt\WifiWatch\state.txt'
$script:RnLines = New-Object System.Collections.ArrayList     # what was said (for the receipt)
$script:RnDone = New-Object System.Collections.ArrayList      # what was changed
if ($null -eq $script:RnOps) { $script:RnOps = $null }       # tests put a simulated Windows here

function Rn-Say([string]$t, [string]$c = '') {
  [void]$script:RnLines.Add($t)
  if ($OutFile) { try { Add-Content -LiteralPath $OutFile -Value $t -Encoding UTF8 } catch {} }
  if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t }
}
function Rn-Changed([string]$t) { [void]$script:RnDone.Add($t); Rn-Say ('  ' + $t) }

# ---------------- the Windows side (tests replace it with $script:RnOps) ----------------
function Invoke-RnOp([string]$op, $a = @{}) {
  if ($script:RnOps) { return (& $script:RnOps $op $a) }
  switch ($op) {
    'isadmin' { try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false } }
    'list' {
      $out = @()
      foreach ($n in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        if ([string]$n.InterfaceDescription -match '(?i)bluetooth|virtual|vpn|tap-|wan miniport') { continue }
        $wifi = ([string]$n.NdisPhysicalMedium -eq '9' -or [string]$n.NdisPhysicalMedium -match '802\.11|Native' -or [string]$n.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|wlan')
        $out += [pscustomobject]@{ name = [string]$n.Name; ifIndex = [int]$n.ifIndex; desc = [string]$n.InterfaceDescription; disabled = ([string]$n.Status -eq 'Disabled' -or [string]$n.AdminStatus -eq 'Down'); connected = ([string]$n.MediaConnectionState -eq 'Connected' -or [string]$n.Status -eq 'Up'); wifi = [bool]$wifi; guid = [string]$n.InterfaceGuid }
      }
      return $out
    }
    'state' {
      $ix = [int]$a.ifIndex; $r = [ordered]@{ dhcp = $false; coexist = 'unknown'; active = @(); persistent = @(); routes = @(); dnsStatic = $false }
      $ipi = Get-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue
      $r.dhcp = ($ipi -and [string]$ipi.Dhcp -eq 'Enabled')
      try { $t = (netsh interface ipv4 show interface ([string]$ix)) -join "`n"; $m = [regex]::Match($t, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)'); if ($m.Success) { $r.coexist = $m.Groups[1].Value.ToLower() } } catch {}
      $r.active = @(Get-NetIPAddress -InterfaceIndex $ix -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = [string]$_.PrefixOrigin } })
      $r.persistent = @(Get-NetIPAddress -InterfaceIndex $ix -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = 'Manual' } })
      # a fixed router address is the one Windows SAVED (PersistentStore); a DHCP router address is never saved. Its live copy goes too.
      $pr = @(Get-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop })
      $rt = @($pr | ForEach-Object { [pscustomobject]@{ gw = $_; store = 'PersistentStore'; manual = $true } })
      $rt += @(Get-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ gw = [string]$_.NextHop; store = 'ActiveStore'; manual = ($pr -contains [string]$_.NextHop) } })
      $r.routes = $rt
      try { $g = [string]$a.guid; if ($g) { $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $g; $ns = [string](Get-ItemProperty -LiteralPath $k -Name NameServer -ErrorAction SilentlyContinue).NameServer; $r.dnsStatic = [bool]($ns.Trim()) } } catch {}
      return [pscustomobject]$r
    }
    'enable' { Enable-NetAdapter -Name $a.name -Confirm:$false -ErrorAction Stop; return $true }
    'dhcp' { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop; return $true }
    'removeaddr' {
      Remove-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $a.ip -PolicyStore $a.store -Confirm:$false -ErrorAction SilentlyContinue
      if ($a.store -eq 'PersistentStore') { $null = netsh interface ipv4 delete address ([string]$a.ifIndex) ('address=' + $a.ip) 2>$null }
      return $true
    }
    'removeroute' { Remove-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $a.gw -PolicyStore $a.store -Confirm:$false -ErrorAction SilentlyContinue; return $true }
    'dnsreset' { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop; return $true }
    'coexist' { $null = netsh interface ipv4 set interface ([string]$a.ifIndex) ('dhcpstaticipcoexistence=' + $(if ($a.on) { 'enabled' } else { 'disabled' })); return ($LASTEXITCODE -eq 0) }
    'reconnect' {
      if ($a.wifi) {
        $prof = ''
        try { $t = (netsh wlan show interfaces) -join "`n"; $m = [regex]::Match($t, '(?m)^\s*Profile\s*:\s*(.+?)\s*$'); if ($m.Success) { $prof = $m.Groups[1].Value } } catch {}
        if (-not $prof) { try { $t = (netsh wlan show profiles ('interface=' + $a.name)) -join "`n"; $m = [regex]::Match($t, '(?m)All User Profile\s*:\s*(.+?)\s*$'); if ($m.Success) { $prof = $m.Groups[1].Value } } catch {} }
        if ($prof) { $null = netsh wlan connect ('name=' + $prof) ('interface=' + $a.name) }
        return $prof
      }
      try { $p = Start-Process -FilePath 'ipconfig.exe' -ArgumentList ('/renew "' + $a.name + '"') -WindowStyle Hidden -PassThru; if (-not $p.WaitForExit(40000)) { try { $p.Kill() } catch {} } } catch {}
      return 'renew'
    }
    'task' {
      $t = Get-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction SilentlyContinue
      if (-not $t) { return 'none' }
      if ($a.set -eq 'off') { Disable-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop | Out-Null; try { Set-Content -LiteralPath $script:RnWifiWatchState -Value 0 } catch {}; return 'off' }
      if ($a.set -eq 'on') { Enable-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop | Out-Null; return 'on' }
      return $(if ([string]$t.State -eq 'Disabled') { 'off' } else { 'on' })
    }
    'sleep' { Start-Sleep -Seconds ([int]$a.s); return $true }
    'elevate' {
      $exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
      $al = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Elevated -Auto -Adapter "' + $a.name + '" -OutFile "' + $a.out + '" -ToolkitDir "' + $ToolkitDir + '" -FixNvrState "' + $FixNvrState + '" -ReceiptDir "' + $ReceiptDir + '"'
      try { $p = Start-Process -FilePath $exe -ArgumentList $al -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop } catch { return $null }
      try { $null = $p.Handle } catch {}   # keeps the handle, so the exit code can be read later
      return $p
    }
  }
}

# ---------------- the Toolkit's own records (which addresses it put on, what the adapter was before) ----------------
function Get-RnJournals {
  $j = @()
  foreach ($f in @($script:RnFixSiteState, $FixNvrState)) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    $o = $null; try { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch {}
    $temps = @(); $ix = -1; $co = ''
    if ($o) {
      if ($o.PSObject.Properties['temps']) { $temps = @($o.temps | Where-Object { $_ -and $_.ip }) } else { $temps = @($o | Where-Object { $_ -and $_.ip }) }
      if ($o.PSObject.Properties['before'] -and $o.before) { $ix = [int]$o.before.ifIndex; $co = [string]$o.before.coexist }
      if ($o.PSObject.Properties['pc'] -and $o.pc -and $o.pc.PSObject.Properties['coexistence_before'] -and $o.pc.coexistence_before) { $co = $(if ([string]$o.pc.coexistence_before -match '(?i)enabled') { 'enabled' } else { 'disabled' }) }
      if ($ix -lt 0 -and $temps.Count) { $ix = [int]$temps[0].ifIndex }
    }
    $j += [pscustomobject]@{ file = $f; readable = [bool]$o; ifIndex = $ix; coexist = $co; ips = @($temps | ForEach-Object { [string]$_.ip }) }
  }
  return $j
}

function Get-RnPlan($ad, $st, $journals) {
  # what has to change for this adapter to be "normal": DHCP on, no fixed address (live or saved), no fixed gateway, DNS automatic,
  # coexistence as it was (off unless the Toolkit's record says it was on), the adapter on
  $p = New-Object System.Collections.ArrayList
  if ($ad.disabled) { [void]$p.Add([pscustomobject]@{ op = 'enable'; what = 'turn the adapter on' }) }
  if (-not $st.dhcp) { [void]$p.Add([pscustomobject]@{ op = 'dhcp'; what = 'DHCP on (the router gives the address)' }) }
  foreach ($x in @($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' })) { [void]$p.Add([pscustomobject]@{ op = 'removeaddr'; ip = [string]$x.ip; store = 'ActiveStore'; what = ('take off the fixed address ' + $x.ip + ' (live copy)') }) }
  foreach ($x in @($st.persistent | Where-Object { $_ })) { [void]$p.Add([pscustomobject]@{ op = 'removeaddr'; ip = [string]$x.ip; store = 'PersistentStore'; what = ('take off the fixed address ' + $x.ip + ' (saved copy, it would come back after a restart)') }) }
  foreach ($r in @($st.routes | Where-Object { $_ -and $_.manual })) { [void]$p.Add([pscustomobject]@{ op = 'removeroute'; gw = [string]$r.gw; store = [string]$r.store; what = ('take off the fixed router address ' + $r.gw + $(if ($r.store -eq 'PersistentStore') { ' (saved copy)' } else { ' (live copy)' })) }) }
  if ($st.dnsStatic) { [void]$p.Add([pscustomobject]@{ op = 'dnsreset'; what = 'DNS back to automatic' }) }
  $want = 'disabled'; foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex -and $_.coexist })) { $want = $(if ($j.coexist -match '(?i)enabled') { 'enabled' } else { 'disabled' }) }
  if ([string]$st.coexist -ne 'unknown' -and [string]$st.coexist -ne $want) { [void]$p.Add([pscustomobject]@{ op = 'coexist'; on = ($want -eq 'enabled'); what = ('DHCP+static coexistence back to ' + $want) }) }
  return $p.ToArray()
}

function Test-RnNormal($ad, $st, $journals) {
  # returns the list of things that are NOT normal (empty = normal)
  $bad = @()
  if ($ad.disabled) { $bad += 'the adapter is still turned off' }
  if (-not $st.dhcp) { $bad += 'DHCP is not on' }
  foreach ($x in @($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' })) { $bad += ('the fixed address ' + $x.ip + ' is still on (live copy)') }
  foreach ($x in @($st.persistent | Where-Object { $_ })) { $bad += ('the fixed address ' + $x.ip + ' is still saved (it comes back after a restart)') }
  foreach ($r in @($st.routes | Where-Object { $_ -and $_.manual })) { $bad += ('the fixed router address ' + $r.gw + ' is still set') }
  if ($st.dnsStatic) { $bad += 'DNS is still set by hand' }
  $want = 'disabled'; foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex -and $_.coexist })) { $want = $(if ($j.coexist -match '(?i)enabled') { 'enabled' } else { 'disabled' }) }
  if ([string]$st.coexist -ne 'unknown' -and [string]$st.coexist -ne $want) { $bad += ('DHCP+static coexistence is ' + $st.coexist + ', should be ' + $want) }
  foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex })) { foreach ($ip in @($j.ips)) { if (@($st.active + $st.persistent | Where-Object { $_ -and [string]$_.ip -eq $ip }).Count) { $bad += ('the Toolkit''s temporary address ' + $ip + ' is still on') } } }
  return $bad
}

function Get-RnLease($st) {
  $l = @($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Dhcp' -and [string]$_.ip -notlike '169.254.*' })
  if ($l.Count) { return [string]$l[0].ip }
  return ''
}

function Write-RnReceipt([string]$result, $ad) {
  try {
    $dirs = @($ReceiptDir); if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA 'WireIt\receipts') }; $dirs += (Join-Path ([IO.Path]::GetTempPath()) 'WireIt-receipts')
    $f = ''; $name = 'RestoreNetwork-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt'
    $l = @(('WireIt Toolkit ' + $script:RnVersion + ' - Restore Network receipt'), ('PC: ' + $env:COMPUTERNAME + '   user: ' + $env:USERNAME + '   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), ('Adapter: ' + $(if ($ad) { $ad.name } else { '(none)' })), ('Result: ' + $result), '', 'Changed:')
    if ($script:RnDone.Count) { $l += @($script:RnDone | ForEach-Object { '  - ' + $_ }) } else { $l += '  - nothing (it was already normal)' }
    $l += @('', 'What it said:') + @($script:RnLines | ForEach-Object { '  ' + $_ })
    # Toolkit\receipts first; a login that may not write there (Crew) keeps it in its own folder
    foreach ($d in $dirs) { try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null; $f = Join-Path $d $name; [IO.File]::WriteAllLines($f, [string[]]$l); return $f } catch { $f = '' } }
    return ''
  } catch { return '' }
}

function Select-RnAdapter($ads, $journals) {
  # the adapter that needs it most: one the Toolkit's records name, else one that is off or has a fixed address, else the cable one
  if ($Adapter) {
    $m = @($ads | Where-Object { $_.name -ieq $Adapter })
    if ($m.Count) { return $m[0] }
    return $null
  }
  $sug = $null
  foreach ($j in @($journals)) { if (-not $sug -and $j.ifIndex -ge 0) { $sug = @($ads | Where-Object { $_.ifIndex -eq $j.ifIndex })[0] } }
  if (-not $sug) { foreach ($x in @($ads)) { if (-not $sug -and $x.needs) { $sug = $x } } }
  if (-not $sug) { $sug = @($ads | Where-Object { -not $_.wifi })[0] }
  if (-not $sug) { $sug = @($ads)[0] }
  if ($Auto -or @($ads).Count -le 1 -or $script:RnNoAsk) { return $sug }
  Rn-Say 'Which network adapter should go back to normal?'
  $i = 0; foreach ($x in @($ads)) { $i++; Rn-Say ('  ' + $i + '. ' + $x.name + ' (' + $x.desc + ')' + $(if ($x.needs) { '  <- not normal' } else { '' }) + $(if ($x -eq $sug) { '  [Enter]' } else { '' })) }
  $ans = ''; try { $ans = [string](Read-Host 'Number') } catch {}
  if (-not $ans.Trim()) { return $sug }
  $n = 0; if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le @($ads).Count) { return @($ads)[$n - 1] }
  return $null
}

function Move-RnJournals($ad, $journals) {
  # the adapter checked back to normal: the Toolkit's records for THIS adapter are done (kept, renamed, never deleted)
  foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex -and $_.readable })) {
    $to = $j.file -replace '\.json$', ('.restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    try { Move-Item -LiteralPath $j.file -Destination $to -Force; Rn-Say ('  the Toolkit''s record ' + (Split-Path -Leaf $j.file) + ' is done (kept as ' + (Split-Path -Leaf $to) + ')') } catch {}
  }
}

# ================================ main ================================
function Invoke-RestoreNetwork {
  $ads = @(Invoke-RnOp 'list')
  $journals = @(Get-RnJournals)
  foreach ($x in $ads) {
    $needs = $false
    try { $st0 = Invoke-RnOp 'state' @{ ifIndex = $x.ifIndex; guid = $x.guid }; $needs = (@(Test-RnNormal $x $st0 $journals).Count -gt 0) } catch {}
    $x | Add-Member -NotePropertyName needs -NotePropertyValue $needs -Force
  }
  if ($List) { [Console]::Out.WriteLine('JSON=' + (ConvertTo-Json -Compress -Depth 4 -InputObject @($ads | ForEach-Object { [ordered]@{ name = $_.name; desc = $_.desc; wifi = $_.wifi; disabled = $_.disabled; needs = $_.needs } }))); return 0 }
  if (-not $Elevated) { Rn-Say ('=== Restore Network (WireIt Toolkit ' + $script:RnVersion + ') ===') 'Cyan' }
  if (-not $ads.Count) { Rn-Say 'No network adapter found on this PC. Nothing was changed.' 'Yellow'; return 2 }
  $ad = Select-RnAdapter $ads $journals
  if (-not $ad) {
    Rn-Say ('There is no network adapter called "' + $Adapter + '" on this PC. Nothing was changed.') 'Yellow'
    Rn-Say ('This PC has: ' + (($ads | ForEach-Object { $_.name }) -join ', ') + '. Pick one of those and run again.')
    return 2
  }
  $st = Invoke-RnOp 'state' @{ ifIndex = $ad.ifIndex; guid = $ad.guid }
  $plan = @(Get-RnPlan $ad $st $journals)
  if (-not $Elevated) { Rn-Say ('Adapter: ' + $ad.name + ' (' + $ad.desc + ')') }
  # nothing to change: no admin rights needed, no Windows permission question
  if (-not $plan.Count) {
    $lease = Get-RnLease $st
    if ($lease -or -not $ad.connected) {
      Rn-Say 'Nothing needed changing.'
      return (Complete-RnRun $ad $st $journals)
    }
  }
  $admin = [bool](Invoke-RnOp 'isadmin')
  if (-not $admin) {
    if ($NoElevate -or $Elevated) { Rn-Say 'This needs admin rights, and this copy has none. Nothing was changed.' 'Red'; Rn-Say 'FAILED - Run again (and click Yes when Windows asks).' 'Red'; [void](Write-RnReceipt 'FAILED - no admin rights, nothing changed' $ad); return 6 }
    Rn-Say 'Windows asks permission next: click Yes.'
    $out = Join-Path ([IO.Path]::GetTempPath()) ('wireit-restorenet-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $p = Invoke-RnOp 'elevate' @{ name = $ad.name; out = $out }
    if (-not $p) { Rn-Say 'Windows asked for permission and it was not given, so nothing was changed.' 'Red'; Rn-Say 'FAILED - Run again (and click Yes when Windows asks).' 'Red'; [void](Write-RnReceipt 'FAILED - permission not given, nothing changed' $ad); return 6 }
    # show what the admin copy says while it works; its exit code is this run's
    $off = 0; $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
      $ex = $true; try { $ex = $p.HasExited } catch {}
      try { if (Test-Path -LiteralPath $out) { $all = [IO.File]::ReadAllLines($out); for ($i = $off; $i -lt $all.Count; $i++) { $c = $(if ($all[$i] -match '^FAILED') { 'Red' } elseif ($all[$i] -match '^DONE') { 'Green' } else { '' }); if ($c) { Write-Host $all[$i] -ForegroundColor $c } else { Write-Host $all[$i] } }; $off = $all.Count } } catch {}
      if ($ex) { break }
      if ((Get-Date) -gt $deadline) { Write-Host 'FAILED - Run again. The admin part did not finish in 5 minutes.' -ForegroundColor Red; return 6 }
      [void](Invoke-RnOp 'sleep' @{ s = 1 })
    }
    $code = 6; try { $code = [int]$p.ExitCode } catch {}
    try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch {}
    return $code
  }
  # admin: do it. WifiWatch is switched off while this works and ALWAYS back on (try/finally)
  $ww = 'none'; $wwOff = $false; $failed = @()
  try {
    try { $ww = [string](Invoke-RnOp 'task' @{ set = '' }) } catch { $ww = 'none' }
    if ($ww -eq 'on') { try { [void](Invoke-RnOp 'task' @{ set = 'off' }); $wwOff = $true; Rn-Say '  WifiWatch paused while this works' } catch { Rn-Say ('  WifiWatch could not be paused: ' + $_.Exception.Message) 'Yellow' } }
    Rn-Say 'Putting it back:'
    # the adapter on and DHCP first, so the PC can get an address even if a later step fails
    foreach ($s in @($plan | Where-Object { $_.op -eq 'enable' }) + @($plan | Where-Object { $_.op -eq 'dhcp' }) + @($plan | Where-Object { $_.op -notin @('enable', 'dhcp') })) {
      try {
        $a = @{ ifIndex = $ad.ifIndex; name = $ad.name; guid = $ad.guid }
        foreach ($k in @('ip', 'store', 'gw', 'on')) { if ($s.PSObject.Properties[$k]) { $a[$k] = $s.$k } }
        $ok = Invoke-RnOp $s.op $a
        if ($ok -eq $false) { throw 'Windows said no' }
        Rn-Changed $s.what
        if ($s.op -eq 'enable') { [void](Invoke-RnOp 'sleep' @{ s = 4 }) }
      } catch { $failed += ($s.what + ': ' + $_.Exception.Message); Rn-Say ('  NOT DONE: ' + $s.what + ' (' + $_.Exception.Message + ')') 'Red' }
    }
    # reconnect, then wait for the router's address
    $ad2 = @(@(Invoke-RnOp 'list') | Where-Object { $_.ifIndex -eq $ad.ifIndex })[0]; if ($ad2) { $ad = $ad2 }
    try { $rc = Invoke-RnOp 'reconnect' @{ ifIndex = $ad.ifIndex; name = $ad.name; wifi = $ad.wifi }; if ($ad.wifi) { Rn-Changed $(if ($rc) { 'Wi-Fi reconnected to "' + $rc + '"' } else { 'Wi-Fi: no saved network to reconnect to' }) } else { Rn-Changed 'asked the router for a new address' } } catch { Rn-Say ('  reconnect did not work: ' + $_.Exception.Message) 'Yellow' }
  } finally {
    if ($wwOff) { try { [void](Invoke-RnOp 'task' @{ set = 'on' }); Rn-Say '  WifiWatch is back on' } catch { $failed += 'WifiWatch could not be switched back on'; Rn-Say '  WifiWatch could not be switched back on' 'Red' } }
  }
  $st2 = $null
  for ($w = 0; $w -le [Math]::Max(0, $WaitSeconds); $w += 2) {
    $ad3 = @(@(Invoke-RnOp 'list') | Where-Object { $_.ifIndex -eq $ad.ifIndex })[0]; if ($ad3) { $ad = $ad3 }
    $st2 = Invoke-RnOp 'state' @{ ifIndex = $ad.ifIndex; guid = $ad.guid }
    if (Get-RnLease $st2) { break }
    if ((-not $ad.connected) -and $w -ge 10) { break }
    [void](Invoke-RnOp 'sleep' @{ s = 2 })
  }
  return (Complete-RnRun $ad $st2 $journals $failed)
}

function Complete-RnRun($ad, $st, $journals, $failed = @()) {
  # the end: read back, say DONE or FAILED - Run again, write the receipt
  $bad = @(Test-RnNormal $ad $st $journals) + @($failed | Where-Object { $_ -match 'WifiWatch' })
  $lease = Get-RnLease $st
  if (-not $bad.Count -and $ad.connected -and -not $lease) { $bad += 'no address from the router yet (DHCP did not answer)' }
  if ($bad.Count) {
    Rn-Say ''
    foreach ($b in $bad) { Rn-Say ('  still wrong: ' + $b) 'Red' }
    Rn-Say 'FAILED - Run again. This PC''s network is NOT back to normal yet. If it fails twice, restart the PC.' 'Red'
    $r = Write-RnReceipt ('FAILED - Run again (' + ($bad -join '; ') + ')') $ad
    if ($r) { Rn-Say ('Receipt: ' + $r) }
    return 6
  }
  if (@($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex }).Count) { Move-RnJournals $ad $journals }
  Rn-Say ''
  if ($lease) { Rn-Say ('DONE - network is back to normal (' + $ad.name + ': DHCP, address ' + $lease + ' from the router).') 'Green' }
  else { Rn-Say ('DONE - network is back to normal (' + $ad.name + ': DHCP). It is not connected right now: plug the cable in / pick the Wi-Fi, and it gets its address by itself.') 'Green' }
  $r = Write-RnReceipt 'DONE - network is back to normal' $ad
  if ($r) { Rn-Say ('Receipt: ' + $r) }
  return 0
}

if ($MyInvocation.InvocationName -ne '.') {
  $code = 6
  try { $code = @(Invoke-RestoreNetwork)[-1] } catch { Rn-Say ('FAILED - Run again. Restore Network stopped: ' + $_.Exception.Message) 'Red'; try { [void](Write-RnReceipt ('FAILED - stopped: ' + $_.Exception.Message) $null) } catch {}; $code = 6 }
  exit $code
}
