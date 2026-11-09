<#
 RestoreNetwork.ps1 - WireIt Toolkit 2.2.12: "Restore Network". ONE button: this PC's network adapter goes back to normal.
 Moshe Nov 9 2026 (add-on #3): the crew runs it, the laptop ends up as it was; running it twice is fine; a run that could not finish
 says "FAILED - Run again". No Tab and no AI inside; it runs on its own (Toolkit button, "Restore Network.cmd", or this file).

 What it does to the CHOSEN adapter (nothing else is touched):
   0. 2.2.12 (Codex P1-3): saves its OWN before-snapshot of the adapter (DHCP flag, addresses live+saved, routes, DNS) as
      receipts\RestoreNetwork-<time>-before.json BEFORE it changes anything, and says where it is
   1. pauses WifiWatch while it works (2.2.12, Codex P1-7): writes the pause file %ProgramData%\WireIt\wifiwatch.pause (WifiWatch.ps1
      reads it before every reset step and does nothing while it is fresh; an expired one is ignored, so a crashed run never
      stops the watcher for good), switches the task off, waits for / stops a copy that is already running, and keeps the
      pause until the FINAL online check is done; then ALWAYS back on (try/finally). A pause that failed is never DONE.
   2. turns the adapter on if it is disabled
   3. DHCP on (the router gives the address). 2.2.12 (Codex P1-3): an adapter with a FIXED address of its own (not one the
      Toolkit put on) is NOT switched silently: it says "This adapter has a fixed address X (gateway Y). Restore Network will
      switch it to automatic (DHCP). Its old settings are saved in <file>." and asks (type Y). No answer possible (-Auto, the
      Toolkit button) or not Y = the fixed address, gateway and DNS stay as they are; only the Toolkit's own temporary addresses
      (named in its records) come off. -ResetStatic = the crew already said yes.
   4. takes off every fixed (manual) IPv4 address the Toolkit or a tech put on: BOTH copies, the live one and the saved
      (persistent) one - "netsh interface ipv4 add address" saves it, so a live-only removal comes back after a restart
   5. takes off a fixed default gateway (both copies) and puts DNS back to automatic
   6. DHCP+static coexistence back to off (or to what the Toolkit's own record says it was before)
   7. reconnects (Wi-Fi: its saved network; cable: asks the router for an address) and waits for the address
   8. reads the adapter back, checks the PC is REALLY online (~40 s): 2.2.12 (Codex P1-6) online = a real web request
      (Microsoft's connect-test page) sent FROM this adapter's own address (the socket is bound to it, so another adapter
      cannot make it look online); a DNS answer alone is not online; a router that does not answer ping is only noted. Ends with
      "DONE - network is back to normal and online", "NOT FIXED - run again or call" (still offline) or "FAILED - Run again"
 Windows asks for permission (UAC) only when something really has to change; an adapter that is already normal needs no admin.
 A short receipt of what was changed is saved in Toolkit\receipts\ (plain text).
 Exit codes: 0 done (and online), 2 could not start (nothing changed), 6 FAILED - Run again, 8 NOT FIXED - settings normal but still offline (run again or call).
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
  [int]$OnlineSeconds = 40,         # 2.2.11 round 2: how long the online check keeps trying (link, address, router ping, DNS/web) before NOT FIXED
  [switch]$NoElevate,               # tests: never ask Windows for admin rights
  [switch]$ResetStatic,             # 2.2.12 (P1-3): the crew already said yes to switching an adapter with its own fixed address to DHCP
  [string]$PauseFile = ''           # 2.2.12 (P1-7): WifiWatch's pause file (default %ProgramData%\WireIt\wifiwatch.pause)
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:RnVersion = '2.2.12'
if (-not $ToolkitDir) { $ToolkitDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $FixNvrState) { $FixNvrState = Join-Path (Join-Path (Join-Path (Split-Path -Parent $ToolkitDir) 'FixNVR') 'state') 'temp-ips.json' }
if (-not $ReceiptDir) { $ReceiptDir = Join-Path $ToolkitDir 'receipts' }
$script:RnFixSiteState = Join-Path (Join-Path (Join-Path $ToolkitDir 'fixsite-runs') '_state') 'fixsite-temp-ips.json'
$script:RnWifiWatchTask = 'WireIt WifiWatch'
$script:RnWifiWatchState = 'C:\WireIt\WifiWatch\state.txt'
if (-not $PauseFile) { $pd = $env:ProgramData; if (-not $pd) { $pd = [IO.Path]::GetTempPath() }; $PauseFile = Join-Path (Join-Path $pd 'WireIt') 'wifiwatch.pause' }
$script:RnPauseFile = $PauseFile                               # 2.2.12 (P1-7): WifiWatch.ps1 does nothing while this is fresh
$script:RnPauseMinutes = 10                                    # the pause expires by itself (a crashed run never stops WifiWatch for good)
$script:RnAnswer = $null                                       # tests: the crew's answer to the fixed-address question
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
      $ix = [int]$a.ifIndex; $r = [ordered]@{ dhcp = $false; coexist = 'unknown'; active = @(); persistent = @(); routes = @(); dnsStatic = $false; dnsServers = @() }
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
      $r.dnsServers = @(); try { $r.dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | ForEach-Object { [string]$_ }) } catch {}
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
        # 2.2.11 round 2 (Sitebox 2, Nov 9): the profile is only what we ASK for; the network Windows really joins is read back
        # afterwards ('wlan') and that is what is reported. Ask for the network it is on, else a saved one that is in range now.
        $cur = Get-RnWlan $a.name
        $prof = ''
        if ($cur.connected -and $cur.profile) { $prof = $cur.profile }
        if (-not $prof) {
          $pt = ''; $nt = ''
          try { $pt = (netsh wlan show profiles ('interface=' + $a.name)) -join "`n" } catch {}
          try { $nt = (netsh wlan show networks ('interface=' + $a.name)) -join "`n" } catch {}
          $prof = Select-RnWifiProfile $pt $nt
        }
        if ($prof) { $null = netsh wlan connect ('name=' + $prof) ('interface=' + $a.name) }
        for ($i = 0; $i -lt 8; $i++) { Start-Sleep -Seconds 2; if ((Get-RnWlan $a.name).connected) { break } }
        return $prof
      }
      try { $p = Start-Process -FilePath 'ipconfig.exe' -ArgumentList ('/renew "' + $a.name + '"') -WindowStyle Hidden -PassThru; if (-not $p.WaitForExit(40000)) { try { $p.Kill() } catch {} } } catch {}
      return 'renew'
    }
    'wlan' { return (Get-RnWlan $a.name) }
    'online' {
      # 2.2.12 (Codex P1-6): online = a REAL web request (Microsoft's connect-test page, the one Windows itself uses) sent FROM this
      # adapter's own address: the socket is bound to it, and Windows (strong host model) sends a bound socket out of the adapter that
      # owns the address, so another adapter cannot make this one look online. A DNS answer alone is not online; the router ping is noted only.
      $ix = [int]$a.ifIndex; $r = [ordered]@{ link = $false; ip = ''; gw = ''; gwPing = $false; dns = $false; http = $false; httpAny = $false; httpIf = -1; ssid = ''; assoc = $false }
      $n = Get-NetAdapter -InterfaceIndex $ix -ErrorAction SilentlyContinue; $r.link = [bool]($n -and [string]$n.Status -eq 'Up')
      $ips = @(Get-NetIPAddress -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { [string]$_.IPAddress -notlike '169.254.*' -and [string]$_.IPAddress -notlike '127.*' -and [string]$_.AddressState -eq 'Preferred' -and -not $_.SkipAsSource })
      if ($ips.Count) { $r.ip = [string]$ips[0].IPAddress }
      $gws = @(Get-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { [string]$_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric)
      if ($gws.Count) { $r.gw = [string]$gws[0].NextHop }
      if ($a.wifi) { $w = Get-RnWlan $a.name; $r.ssid = $w.ssid; $r.assoc = $w.connected }
      if ($r.link -and $r.ip) {
        if ($r.gw) { try { $pg = New-Object System.Net.NetworkInformation.Ping; for ($i = 0; $i -lt 3 -and -not $r.gwPing; $i++) { try { $r.gwPing = ([string]$pg.Send($r.gw, 1500).Status -eq 'Success') } catch {} } } catch {} }
        $targets = @(); try { $targets = @([Net.Dns]::GetHostAddresses('www.msftconnecttest.com') | Where-Object { $_.AddressFamily -eq 'InterNetwork' }); $r.dns = ($targets.Count -gt 0) } catch {}
        foreach ($t in $targets) { if (-not $r.http) { $r.http = Test-RnHttpFrom $r.ip $t; if ($r.http) { $r.httpIf = $ix } } }
        if (-not $r.http) {
          # not through this adapter: is the PC online some other way? (only to say so honestly; it never makes this adapter DONE)
          try { $wr = Invoke-WebRequest -UseBasicParsing -Uri 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 6 -ErrorAction Stop; $r.httpAny = ([string]$wr.Content -like 'Microsoft Connect Test*') } catch {}
          if ($r.httpAny -and $targets.Count) { try { $fr = @(Find-NetRoute -RemoteIPAddress ([string]$targets[0]) -ErrorAction Stop | Where-Object { $_.PSObject.Properties['InterfaceIndex'] })[0]; if ($fr) { $r.httpIf = [int]$fr.InterfaceIndex } } catch {} }
        }
      }
      return [pscustomobject]$r
    }
    'task' {
      $t = Get-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction SilentlyContinue
      if (-not $t) { return 'none' }
      if ($a.set -eq 'off') { Disable-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop | Out-Null; try { Set-Content -LiteralPath $script:RnWifiWatchState -Value 0 } catch {}; return 'off' }
      if ($a.set -eq 'on') { Enable-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop | Out-Null; return 'on' }
      return $(if ([string]$t.State -eq 'Disabled') { 'off' } else { 'on' })
    }
    # 2.2.12 (Codex P1-7): Disable-ScheduledTask only stops FUTURE runs; a copy that is already running is waited for / stopped
    'taskrunning' { $t = Get-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction SilentlyContinue; return [bool]($t -and [string]$t.State -eq 'Running') }
    'taskstop' { Stop-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop; return $true }
    'pause' { if ($a.set -eq 'on') { return (Write-RnPauseFile $script:RnPauseFile $script:RnPauseMinutes) }; return (Remove-RnPauseFile $script:RnPauseFile) }
    'sleep' { Start-Sleep -Seconds ([int]$a.s); return $true }
    'elevate' {
      $exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
      $al = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Elevated -Auto -Adapter "' + $a.name + '" -OutFile "' + $a.out + '" -ToolkitDir "' + $ToolkitDir + '" -FixNvrState "' + $FixNvrState + '" -ReceiptDir "' + $ReceiptDir + '" -PauseFile "' + $script:RnPauseFile + '"' + $(if ($a.reset) { ' -ResetStatic' } else { '' })
      try { $p = Start-Process -FilePath $exe -ArgumentList $al -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop } catch { return $null }
      try { $null = $p.Handle } catch {}   # keeps the handle, so the exit code can be read later
      return $p
    }
  }
}

# ---------------- the Toolkit's own records (which addresses it put on, what the adapter was before) ----------------
# ---------------- 2.2.11 round 2: what the Wi-Fi is REALLY on, and is the PC really online ----------------
# netsh wlan show interfaces -> the block of ONE interface: connected or not, its SSID and profile (English Windows output)
function ConvertFrom-RnWlanText([string]$text, [string]$name) {
  $r = [pscustomobject]@{ connected = $false; state = ''; ssid = ''; profile = '' }
  if (-not $text) { return $r }
  $blocks = @([regex]::Split($text, '(?m)^(?=\s*Name\s*:)') | Where-Object { $_ -match '(?m)^\s*Name\s*:' })
  $b = $null
  foreach ($x in $blocks) { $m = [regex]::Match($x, '(?m)^\s*Name\s*:\s*(.+?)\s*$'); if ($m.Success -and (-not $name -or $m.Groups[1].Value -eq $name)) { $b = $x; break } }
  if (-not $b -and $blocks.Count -eq 1 -and -not $name) { $b = $blocks[0] }
  if (-not $b) { return $r }
  $m = [regex]::Match($b, '(?m)^\s*State\s*:\s*(.+?)\s*$'); if ($m.Success) { $r.state = $m.Groups[1].Value }
  $m = [regex]::Match($b, '(?m)^\s*SSID\s*:\s*(.+?)\s*$'); if ($m.Success) { $r.ssid = $m.Groups[1].Value }
  $m = [regex]::Match($b, '(?m)^\s*Profile\s*:\s*(.+?)\s*$'); if ($m.Success) { $r.profile = $m.Groups[1].Value }
  $r.connected = ($r.state -eq 'connected' -and [bool]$r.ssid)
  return $r
}
function Get-RnWlan([string]$name) { $t = ''; try { $t = (netsh wlan show interfaces) -join "`n" } catch {}; return (ConvertFrom-RnWlanText $t $name) }
# which saved Wi-Fi to ASK for when it is not on one: the first saved profile that is in range now; none in range = none
# (Windows then joins one by itself). The old code took the first saved profile ("Lizard") even when it was not there.
function Select-RnWifiProfile([string]$profilesText, [string]$networksText) {
  $saved = @([regex]::Matches([string]$profilesText, '(?m)^\s*(?:All )?User Profile\s*:\s*(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
  $seen = @([regex]::Matches([string]$networksText, '(?m)^\s*SSID \d+\s*:\s*(.*?)\s*$') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ })
  foreach ($p in $saved) { if ($seen -contains $p) { return [string]$p } }
  return ''
}
# 2.2.12 (Codex P1-6): online = the web answered THROUGH THIS ADAPTER (http is only ever set by a request sent from its own address).
# A DNS answer alone is not online (a router's cached DNS answers with the internet down); the router ping is only noted.
function Test-RnOnlineOk($o, $ad = $null) {
  if (-not ($o -and $o.link -and $o.ip -and ([string]$o.ip -notlike '169.254.*') -and $o.http)) { return $false }
  if ($ad -and $o.PSObject.Properties['httpIf'] -and $null -ne $o.httpIf -and [int]$o.httpIf -ge 0 -and [int]$o.httpIf -ne [int]$ad.ifIndex) { return $false }
  return $true
}
function Get-RnOfflineWhy($o, $ad) {
  if (-not $o) { return 'the connection could not be checked' }
  if (-not $o.link) { if ($ad.wifi) { return 'the Wi-Fi is not connected to any network' } else { return 'no cable link (is the cable plugged in?)' } }
  if (-not $o.ip -or [string]$o.ip -like '169.254.*') { return 'no address from the router (DHCP did not answer)' }
  if ($o.PSObject.Properties['httpIf'] -and $null -ne $o.httpIf -and [int]$o.httpIf -ge 0 -and [int]$o.httpIf -ne [int]$ad.ifIndex -and ($o.http -or ($o.PSObject.Properties['httpAny'] -and $o.httpAny))) { return 'this PC is online through ANOTHER adapter, not through this one' }
  if ($o.PSObject.Properties['httpAny'] -and $o.httpAny) { return 'this PC is online through another adapter, not through this one' }
  if (-not $o.gw) { return 'no router (gateway) address' }
  if (-not $o.gwPing -and -not $o.dns) { return ('the router ' + $o.gw + ' does not answer and the internet does not either') }
  if ($o.dns) { return 'the router and DNS answer, but no web page comes back through this adapter (the internet is down or blocked)' }
  return 'the router answers but the internet does not (no DNS, no web)'
}
# polls the real connection for about $OnlineSeconds; a Wi-Fi that is still not on a network gets one more join request
function Wait-RnOnline($ad) {
  $last = $null; $retried = $false; $deadline = (Get-Date).AddSeconds([Math]::Max(0, $OnlineSeconds))
  $tries = [int][Math]::Ceiling([Math]::Max(0, $OnlineSeconds) / 3) + 1
  for ($i = 0; $i -lt $tries; $i++) {
    try { $last = Invoke-RnOp 'online' @{ ifIndex = $ad.ifIndex; name = $ad.name; wifi = $ad.wifi } } catch { $last = $null }
    if (Test-RnOnlineOk $last $ad) { return $last }
    if ($i -eq 0) { Rn-Say '  checking the connection (router, internet) - up to about 40 seconds ...' }
    if ($ad.wifi -and $last -and -not $last.link -and -not $retried -and $i -ge 3) {
      $retried = $true; Rn-Say '  Wi-Fi still not on a network - asking it to join again'
      try { [void](Invoke-RnOp 'reconnect' @{ ifIndex = $ad.ifIndex; name = $ad.name; wifi = $true }) } catch {}
    }
    if ((Get-Date) -gt $deadline) { break }
    [void](Invoke-RnOp 'sleep' @{ s = 3 })
  }
  return $last
}
function Say-RnWifiJoined($ad) {
  # reports the network Windows is REALLY on, read after the reconnect - never the profile that was asked for
  $w = $null; try { $w = Invoke-RnOp 'wlan' @{ ifIndex = $ad.ifIndex; name = $ad.name } } catch {}
  if ($w -and $w.connected -and $w.ssid) { Rn-Changed ('Wi-Fi connected to "' + $w.ssid + '"') } else { Rn-Say '  Wi-Fi is not on a network yet' 'Yellow' }
}

# ---------------- 2.2.12 (Codex P1-6): a web request sent FROM one adapter's own address ----------------
# PS 5.1 compatible: a TcpClient bound to the adapter's address (Windows' strong host model sends it out of that adapter only)
function Test-RnHttpFrom([string]$fromIp, $target, [int]$port = 80) {
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetwork)
    $c.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($fromIp), 0)))
    $ar = $c.BeginConnect($target, $port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(6000)) { return $false }
    $c.EndConnect($ar)
    $st = $c.GetStream(); $st.ReadTimeout = 6000
    $req = [Text.Encoding]::ASCII.GetBytes("GET /connecttest.txt HTTP/1.1`r`nHost: www.msftconnecttest.com`r`nConnection: close`r`n`r`n")
    $st.Write($req, 0, $req.Length)
    $buf = New-Object byte[] 4096; $txt = ''; $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $txt += [Text.Encoding]::ASCII.GetString($buf, 0, $n); if ($txt -match 'Microsoft Connect Test') { break } }
    return [bool]($txt -match '^HTTP/1\.[01] 200' -and $txt -match 'Microsoft Connect Test')
  } catch { return $false } finally { if ($c) { try { $c.Close() } catch {} } }
}

# ---------------- 2.2.12 (Codex P1-7): the WifiWatch pause file (WifiWatch.ps1 reads the same two lines) ----------------
# line 1 "until=<UTC yyyy-MM-ddTHH:mm:ssZ>" (WifiWatch ignores it once that time has passed, or if it is more than 30 min ahead)
function Write-RnPauseFile([string]$file, [int]$minutes) {
  try {
    $d = Split-Path -Parent $file; if ($d) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null }
    $u = (Get-Date).ToUniversalTime().AddMinutes($minutes).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    [IO.File]::WriteAllLines($file, [string[]]@(('until=' + $u), ('by=Restore Network (WireIt Toolkit ' + $script:RnVersion + ') pid ' + $PID)))
    $back = [IO.File]::ReadAllText($file)
    return [bool]($back -match [regex]::Escape('until=' + $u))
  } catch { return $false }
}
function Remove-RnPauseFile([string]$file) {
  try { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }; return (-not (Test-Path -LiteralPath $file)) } catch { return $false }
}
# pauses WifiWatch: the pause file, the task off (admin), and a copy that is ALREADY running waited for (and stopped if it does not end).
# returns { ok; why; taskOff; file } - ok is $true only when nothing of WifiWatch can act any more
function Start-RnPause([bool]$admin) {
  $r = [pscustomobject]@{ ok = $true; why = ''; taskOff = $false; file = $false; needed = $false }
  $ww = 'none'; try { $ww = [string](Invoke-RnOp 'task' @{ set = '' }) } catch { $ww = 'none' }
  if ($ww -eq 'none') { return $r }   # WifiWatch is not installed on this PC: nothing to pause
  $r.needed = $true
  $f = $false; try { $f = [bool](Invoke-RnOp 'pause' @{ set = 'on' }) } catch {}
  $r.file = $f; if (-not $f) { $r.ok = $false; $r.why = 'its pause file could not be written' }
  if ($ww -eq 'on' -and $admin) {
    try { [void](Invoke-RnOp 'task' @{ set = 'off' }); $r.taskOff = $true } catch { $r.ok = $false; $r.why = ('the task could not be switched off: ' + $_.Exception.Message) }
  }
  # a copy that is running right now: it reads the pause file before its next step and ends; wait for it, then stop it
  $run = $false; try { $run = [bool](Invoke-RnOp 'taskrunning') } catch {}
  for ($i = 0; $run -and $i -lt 15; $i++) { [void](Invoke-RnOp 'sleep' @{ s = 2 }); try { $run = [bool](Invoke-RnOp 'taskrunning') } catch { $run = $false } }
  if ($run -and $admin) { try { [void](Invoke-RnOp 'taskstop'); Rn-Say '  a WifiWatch run that was still going was stopped' } catch {}; try { $run = [bool](Invoke-RnOp 'taskrunning') } catch {} }
  if ($run) { $r.ok = $false; $r.why = 'a WifiWatch run is still going and could not be stopped' }
  if ($r.ok) { Rn-Say '  WifiWatch paused while this works (and while the connection is checked)' } else { Rn-Say ('  WifiWatch could NOT be paused: ' + $r.why) 'Red' }
  return $r
}
function Stop-RnPause($p) {
  # the task back on FIRST, then the pause file off; returns '' or what could not be done
  $err = ''
  if (-not $p -or -not $p.needed) { return '' }
  if ($p.taskOff) { try { [void](Invoke-RnOp 'task' @{ set = 'on' }) } catch { $err = 'WifiWatch could not be switched back on' } }
  $gone = $false; try { $gone = [bool](Invoke-RnOp 'pause' @{ set = 'off' }) } catch {}
  if (-not $gone -and -not $err) { $err = 'WifiWatch''s pause file could not be removed (it runs again by itself within ' + $script:RnPauseMinutes + ' min)' }
  if ($err) { Rn-Say ('  ' + $err) 'Red' } else { Rn-Say '  WifiWatch is back on' }
  return $err
}

# ---------------- 2.2.12 (Codex P1-3): Restore Network's own before-snapshot, written BEFORE any change ----------------
function Save-RnBefore($ad, $st) {
  $o = [ordered]@{ tool = ('WireIt Toolkit ' + $script:RnVersion + ' - Restore Network'); written = (Get-Date -Format 's'); pc = $env:COMPUTERNAME
                   adapter = [ordered]@{ name = $ad.name; ifIndex = $ad.ifIndex; desc = $ad.desc; guid = $ad.guid; wifi = $ad.wifi; disabled = $ad.disabled }
                   dhcp = [bool]$st.dhcp; coexist = [string]$st.coexist; active = @($st.active); persistent = @($st.persistent); routes = @($st.routes); dnsStatic = [bool]$st.dnsStatic
                   dnsServers = $(if ($st.PSObject.Properties['dnsServers']) { @($st.dnsServers) } else { @() }) }
  $dirs = @($ReceiptDir); if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA 'WireIt\receipts') }; $dirs += (Join-Path ([IO.Path]::GetTempPath()) 'WireIt-receipts')
  $name = 'RestoreNetwork-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-before.json'
  foreach ($d in $dirs) { try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null; $f = Join-Path $d $name; [IO.File]::WriteAllText($f, (ConvertTo-Json -Depth 6 -InputObject $o)); if (Test-Path -LiteralPath $f) { return $f } } catch {} }
  return ''
}
# the adapter's OWN fixed setup (DHCP off, not done by the Toolkit): addresses + gateway, '' when it is not one
function Get-RnOwnStatic($ad, $st, $journals) {
  if ($st.dhcp) { return $null }
  foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex -and $_.readable })) { if ($j.dhcpBefore -eq $true) { return $null } }   # the Toolkit's record: it WAS automatic -> the Toolkit turned it off
  $tk = @(); foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex })) { $tk += @($j.ips) }
  $ips = @(@($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' }) + @($st.persistent | Where-Object { $_ }) | ForEach-Object { [string]$_.ip } | Where-Object { $tk -notcontains $_ } | Select-Object -Unique)
  if (-not $ips.Count) { return $null }
  $gws = @($st.routes | Where-Object { $_ -and $_.manual } | ForEach-Object { [string]$_.gw } | Select-Object -Unique)
  return [pscustomobject]@{ ips = $ips; gws = $gws; text = (($ips -join ', ') + $(if ($gws.Count) { ' (gateway ' + ($gws -join ', ') + ')' } else { ' (no gateway)' })) }
}

function Get-RnJournals {
  $j = @()
  foreach ($f in @($script:RnFixSiteState, $FixNvrState)) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    $o = $null; try { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch {}
    $temps = @(); $ix = -1; $co = ''; $dhb = $null
    if ($o) {
      if ($o.PSObject.Properties['temps']) { $temps = @($o.temps | Where-Object { $_ -and $_.ip }) } else { $temps = @($o | Where-Object { $_ -and $_.ip }) }
      if ($o.PSObject.Properties['before'] -and $o.before) { $ix = [int]$o.before.ifIndex; $co = [string]$o.before.coexist; if ($o.before.PSObject.Properties['dhcp'] -and $null -ne $o.before.dhcp) { $dhb = [bool]$o.before.dhcp } }
      # 2.2.12 (P1-3): Fix NVR's record names its adapter and whether it was automatic (DHCP) before Fix NVR touched it
      if ($o.PSObject.Properties['pc'] -and $o.pc) { if ($ix -lt 0 -and $o.pc.PSObject.Properties['ifIndex'] -and $null -ne $o.pc.ifIndex) { $ix = [int]$o.pc.ifIndex }; if ($null -eq $dhb -and $o.pc.PSObject.Properties['dhcp'] -and $null -ne $o.pc.dhcp -and $null -ne $o.pc.ifIndex) { $dhb = [bool]$o.pc.dhcp } }
      if ($o.PSObject.Properties['pc'] -and $o.pc -and $o.pc.PSObject.Properties['coexistence_before'] -and $o.pc.coexistence_before) { $co = $(if ([string]$o.pc.coexistence_before -match '(?i)enabled') { 'enabled' } else { 'disabled' }) }
      if ($ix -lt 0 -and $temps.Count) { $ix = [int]$temps[0].ifIndex }
    }
    $j += [pscustomobject]@{ file = $f; readable = [bool]$o; ifIndex = $ix; coexist = $co; dhcpBefore = $dhb; ips = @($temps | ForEach-Object { [string]$_.ip }) }
  }
  return $j
}

function Get-RnPlan($ad, $st, $journals, [bool]$keep = $false) {
  # what has to change for this adapter to be "normal": DHCP on, no fixed address (live or saved), no fixed gateway, DNS automatic,
  # coexistence as it was (off unless the Toolkit's record says it was on), the adapter on
  # 2.2.12 (Codex P1-3): $keep = the adapter's OWN fixed setup stays (DHCP off, its address, gateway and DNS); only the
  # Toolkit's own temporary addresses (named in its records) and its coexistence change come off
  $p = New-Object System.Collections.ArrayList
  if ($ad.disabled) { [void]$p.Add([pscustomobject]@{ op = 'enable'; what = 'turn the adapter on' }) }
  $tk = @(); foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex })) { $tk += @($j.ips) }
  if (-not $st.dhcp -and -not $keep) { [void]$p.Add([pscustomobject]@{ op = 'dhcp'; what = 'DHCP on (the router gives the address)' }) }
  foreach ($x in @($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' -and (-not $keep -or $tk -contains [string]$_.ip) })) { [void]$p.Add([pscustomobject]@{ op = 'removeaddr'; ip = [string]$x.ip; store = 'ActiveStore'; what = ('take off the ' + $(if ($tk -contains [string]$x.ip) { 'Toolkit''s temporary' } else { 'fixed' }) + ' address ' + $x.ip + ' (live copy)') }) }
  foreach ($x in @($st.persistent | Where-Object { $_ -and (-not $keep -or $tk -contains [string]$_.ip) })) { [void]$p.Add([pscustomobject]@{ op = 'removeaddr'; ip = [string]$x.ip; store = 'PersistentStore'; what = ('take off the ' + $(if ($tk -contains [string]$x.ip) { 'Toolkit''s temporary' } else { 'fixed' }) + ' address ' + $x.ip + ' (saved copy, it would come back after a restart)') }) }
  if (-not $keep) {
    foreach ($r in @($st.routes | Where-Object { $_ -and $_.manual })) { [void]$p.Add([pscustomobject]@{ op = 'removeroute'; gw = [string]$r.gw; store = [string]$r.store; what = ('take off the fixed router address ' + $r.gw + $(if ($r.store -eq 'PersistentStore') { ' (saved copy)' } else { ' (live copy)' })) }) }
    if ($st.dnsStatic) { [void]$p.Add([pscustomobject]@{ op = 'dnsreset'; what = 'DNS back to automatic' }) }
  }
  $want = Get-RnCoexistWant $ad $journals $keep
  if ($want -and [string]$st.coexist -ne 'unknown' -and [string]$st.coexist -ne $want) { [void]$p.Add([pscustomobject]@{ op = 'coexist'; on = ($want -eq 'enabled'); what = ('DHCP+static coexistence back to ' + $want) }) }
  return $p.ToArray()
}
# coexistence as it should be: the Toolkit's record, else off. A kept fixed adapter with no Toolkit record: left as it is ('')
function Get-RnCoexistWant($ad, $journals, [bool]$keep) {
  $mine = @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex -and $_.coexist })
  if ($keep -and -not $mine.Count) { return '' }
  $want = 'disabled'; foreach ($j in $mine) { $want = $(if ($j.coexist -match '(?i)enabled') { 'enabled' } else { 'disabled' }) }
  return $want
}

function Test-RnNormal($ad, $st, $journals, [bool]$keep = $false) {
  # returns the list of things that are NOT normal (empty = normal); $keep (2.2.12, P1-3): the adapter's own fixed setup is normal
  $bad = @()
  if ($ad.disabled) { $bad += 'the adapter is still turned off' }
  $tk = @(); foreach ($j in @($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex })) { $tk += @($j.ips) }
  if (-not $keep) {
    if (-not $st.dhcp) { $bad += 'DHCP is not on' }
    foreach ($x in @($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' -and $tk -notcontains [string]$_.ip })) { $bad += ('the fixed address ' + $x.ip + ' is still on (live copy)') }
    foreach ($x in @($st.persistent | Where-Object { $_ -and $tk -notcontains [string]$_.ip })) { $bad += ('the fixed address ' + $x.ip + ' is still saved (it comes back after a restart)') }
    foreach ($r in @($st.routes | Where-Object { $_ -and $_.manual })) { $bad += ('the fixed router address ' + $r.gw + ' is still set') }
    if ($st.dnsStatic) { $bad += 'DNS is still set by hand' }
  }
  $want = Get-RnCoexistWant $ad $journals $keep
  if ($want -and [string]$st.coexist -ne 'unknown' -and [string]$st.coexist -ne $want) { $bad += ('DHCP+static coexistence is ' + $st.coexist + ', should be ' + $want) }
  foreach ($ip in @($tk | Select-Object -Unique)) {
    if (@($st.active | Where-Object { $_ -and [string]$_.ip -eq $ip }).Count) { $bad += ('the Toolkit''s temporary address ' + $ip + ' is still on (live copy)') }
    if (@($st.persistent | Where-Object { $_ -and [string]$_.ip -eq $ip }).Count) { $bad += ('the Toolkit''s temporary address ' + $ip + ' is still saved (it comes back after a restart)') }
  }
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
# 2.2.12 (Codex P1-3): the crew decides about an adapter's OWN fixed address; returns $true = switch it to automatic
function Confirm-RnResetStatic($own, [string]$beforeFile) {
  if ($ResetStatic) { return $true }
  Rn-Say ('This adapter has a fixed address ' + $own.text + '. Restore Network will switch it to automatic (DHCP).') 'Yellow'
  Rn-Say ('Its old settings are saved in ' + $(if ($beforeFile) { $beforeFile } else { '(the settings file could not be saved)' }) + '.')
  if (-not $beforeFile) { Rn-Say 'Because its old settings could not be saved, the fixed address is kept (nothing of it is changed).' 'Yellow'; return $false }
  $ans = $null
  if ($null -ne $script:RnAnswer) { $ans = [string]$script:RnAnswer }
  elseif ($Auto -or $Elevated) { $ans = '' }
  else { try { $ans = [string](Read-Host 'Type Y to switch it to automatic, or just Enter to keep the fixed address') } catch { $ans = '' } }
  if ($ans.Trim() -match '^(?i)y(es)?$') { return $true }
  Rn-Say ('  Kept: the fixed address ' + $own.text + ' and its DNS stay as they are. Only the Toolkit''s own temporary changes come off.') 'Yellow'
  if ($Auto -or $Elevated) { Rn-Say '  (To switch it to automatic: run "Restore Network.cmd", pick this adapter and type Y.)' }
  return $false
}

function Invoke-RestoreNetwork {
  $ads = @(Invoke-RnOp 'list')
  $journals = @(Get-RnJournals)
  foreach ($x in $ads) {
    $needs = $false
    try { $st0 = Invoke-RnOp 'state' @{ ifIndex = $x.ifIndex; guid = $x.guid }; $keep0 = [bool](Get-RnOwnStatic $x $st0 $journals); $needs = (@(Test-RnNormal $x $st0 $journals $keep0).Count -gt 0) } catch {}
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
  if (-not $Elevated) { Rn-Say ('Adapter: ' + $ad.name + ' (' + $ad.desc + ')') }
  $st = Invoke-RnOp 'state' @{ ifIndex = $ad.ifIndex; guid = $ad.guid }
  # 2.2.12 (Codex P1-3): its OWN before-snapshot, BEFORE anything is changed, and where it is
  $beforeFile = Save-RnBefore $ad $st
  if ($beforeFile) { Rn-Say ('  this adapter''s settings before this run are saved in ' + $beforeFile) } else { Rn-Say '  the settings before this run could NOT be saved' 'Yellow' }
  $own = Get-RnOwnStatic $ad $st $journals
  $keep = $false
  if ($own) { $keep = -not (Confirm-RnResetStatic $own $beforeFile); if (-not $keep) { $script:RnResetStaticOk = $true } }
  $plan = @(Get-RnPlan $ad $st $journals $keep)
  # nothing to change: no admin rights needed, no Windows permission question
  if (-not $plan.Count) {
    $lease = Get-RnLease $st
    if ($keep -or $lease -or -not $ad.connected) {
      Rn-Say 'Nothing needed changing in the settings.'
      $admin0 = $false; try { $admin0 = [bool](Invoke-RnOp 'isadmin') } catch {}
      $pz = $null; $failed0 = @(); $v = $null
      try {
        # 2.2.11 round 2 (Sitebox 2 Wi-Fi drop said DONE while offline): a Wi-Fi that is not on a network is asked to join one
        # 2.2.12 (Codex P1-7): WifiWatch is paused for this too, through the final online check
        if ($ad.wifi -and -not $ad.disabled) {
          $w0 = $null; try { $w0 = Invoke-RnOp 'wlan' @{ ifIndex = $ad.ifIndex; name = $ad.name } } catch {}
          if (-not ($w0 -and $w0.connected)) {
            $pz = Start-RnPause $admin0; if (-not $pz.ok) { $failed0 += ('WifiWatch could not be paused (' + $pz.why + ')') }
            try { [void](Invoke-RnOp 'reconnect' @{ ifIndex = $ad.ifIndex; name = $ad.name; wifi = $true }); Say-RnWifiJoined $ad } catch { Rn-Say ('  reconnect did not work: ' + $_.Exception.Message) 'Yellow' }
            $ad3 = @(@(Invoke-RnOp 'list') | Where-Object { $_.ifIndex -eq $ad.ifIndex })[0]; if ($ad3) { $ad = $ad3 }
            $st = Invoke-RnOp 'state' @{ ifIndex = $ad.ifIndex; guid = $ad.guid }
          }
        }
        $v = Get-RnVerdict $ad $st $journals $failed0 $keep
      } finally { $e0 = Stop-RnPause $pz; if ($e0) { $failed0 += $e0 } }
      return (Complete-RnRun $ad $v $journals $failed0 $keep)
    }
  }
  $admin = [bool](Invoke-RnOp 'isadmin')
  if (-not $admin) {
    if ($NoElevate -or $Elevated) { Rn-Say 'This needs admin rights, and this copy has none. Nothing was changed.' 'Red'; Rn-Say 'FAILED - Run again (and click Yes when Windows asks).' 'Red'; [void](Write-RnReceipt 'FAILED - no admin rights, nothing changed' $ad); return 6 }
    Rn-Say 'Windows asks permission next: click Yes.'
    $out = Join-Path ([IO.Path]::GetTempPath()) ('wireit-restorenet-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $p = Invoke-RnOp 'elevate' @{ name = $ad.name; out = $out; reset = [bool]($own -and -not $keep) }
    if (-not $p) { Rn-Say 'Windows asked for permission and it was not given, so nothing was changed.' 'Red'; Rn-Say 'FAILED - Run again (and click Yes when Windows asks).' 'Red'; [void](Write-RnReceipt 'FAILED - permission not given, nothing changed' $ad); return 6 }
    # show what the admin copy says while it works; its exit code is this run's
    $off = 0; $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
      $ex = $true; try { $ex = $p.HasExited } catch {}
      try { if (Test-Path -LiteralPath $out) { $all = [IO.File]::ReadAllLines($out); for ($i = $off; $i -lt $all.Count; $i++) { $c = $(if ($all[$i] -match '^(FAILED|NOT FIXED)') { 'Red' } elseif ($all[$i] -match '^DONE') { 'Green' } else { '' }); if ($c) { Write-Host $all[$i] -ForegroundColor $c } else { Write-Host $all[$i] } }; $off = $all.Count } } catch {}
      if ($ex) { break }
      if ((Get-Date) -gt $deadline) { Write-Host 'FAILED - Run again. The admin part did not finish in 5 minutes.' -ForegroundColor Red; return 6 }
      [void](Invoke-RnOp 'sleep' @{ s = 1 })
    }
    $code = 6; try { $code = [int]$p.ExitCode } catch {}
    try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch {}
    return $code
  }
  # admin: do it. 2.2.12 (Codex P1-7): WifiWatch is paused (pause file + task off + a running copy waited for / stopped) BEFORE
  # anything changes, stays paused through the FINAL online check, and is ALWAYS back on at the end (try/finally)
  $failed = @(); $pz = $null; $v = $null
  try {
    $pz = Start-RnPause $true
    if (-not $pz.ok) { $failed += ('WifiWatch could not be paused (' + $pz.why + ')') }
    if ($pz.needed) {
      # a WifiWatch run that was stopped may have left things half-way (the adapter off): read the adapter again
      $adR = @(@(Invoke-RnOp 'list') | Where-Object { $_.ifIndex -eq $ad.ifIndex })[0]; if ($adR) { $ad = $adR }
      $st = Invoke-RnOp 'state' @{ ifIndex = $ad.ifIndex; guid = $ad.guid }; $plan = @(Get-RnPlan $ad $st $journals $keep)
    }
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
    try { $rc = Invoke-RnOp 'reconnect' @{ ifIndex = $ad.ifIndex; name = $ad.name; wifi = $ad.wifi }; if ($ad.wifi) { Say-RnWifiJoined $ad } elseif (-not $keep) { Rn-Changed 'asked the router for a new address' } } catch { Rn-Say ('  reconnect did not work: ' + $_.Exception.Message) 'Yellow' }
    $st2 = $null
    for ($w = 0; $w -le [Math]::Max(0, $WaitSeconds); $w += 2) {
      $ad3 = @(@(Invoke-RnOp 'list') | Where-Object { $_.ifIndex -eq $ad.ifIndex })[0]; if ($ad3) { $ad = $ad3 }
      $st2 = Invoke-RnOp 'state' @{ ifIndex = $ad.ifIndex; guid = $ad.guid }
      if ($keep -or (Get-RnLease $st2)) { break }
      if ((-not $ad.connected) -and $w -ge 10) { break }
      [void](Invoke-RnOp 'sleep' @{ s = 2 })
    }
    # the final check runs while WifiWatch is still paused
    $v = Get-RnVerdict $ad $st2 $journals $failed $keep
  } finally {
    $e1 = Stop-RnPause $pz; if ($e1) { $failed += $e1 }
  }
  return (Complete-RnRun $ad $v $journals $failed $keep)
}

# 2.2.12: the read-back and the online check (run while WifiWatch is still paused); the words come after, in Complete-RnRun
function Get-RnVerdict($ad, $st, $journals, $failed, [bool]$keep) {
  $bad = @(Test-RnNormal $ad $st $journals $keep)
  $lease = Get-RnLease $st
  if (-not $bad.Count -and $ad.connected -and -not $lease -and -not $keep) { $bad += 'no address from the router yet (DHCP did not answer)' }
  $on = $null
  if (-not $bad.Count) { $on = Wait-RnOnline $ad }
  return [pscustomobject]@{ bad = $bad; on = $on; checked = [bool](-not $bad.Count) }
}

function Complete-RnRun($ad, $v, $journals, $failed = @(), [bool]$keep = $false) {
  # the end: say DONE or FAILED - Run again / NOT FIXED, write the receipt. A step that failed (also: WifiWatch not paused / not back on) is never DONE
  $bad = @($v.bad) + @($failed | Where-Object { $_ })
  if ($bad.Count) {
    Rn-Say ''
    foreach ($b in $bad) { Rn-Say ('  still wrong: ' + $b) 'Red' }
    Rn-Say 'FAILED - Run again. This PC''s network is NOT back to normal yet. If it fails twice, restart the PC.' 'Red'
    $r = Write-RnReceipt ('FAILED - Run again (' + ($bad -join '; ') + ')') $ad
    if ($r) { Rn-Say ('Receipt: ' + $r) }
    return 6
  }
  if (@($journals | Where-Object { $_.ifIndex -eq $ad.ifIndex }).Count) { Move-RnJournals $ad $journals }
  # 2.2.11 round 2: the settings are normal; DONE only when the PC is REALLY online on this adapter (2.2.12: the web, through it)
  $on = $v.on
  $net = $(if ($ad.wifi -and $on -and $on.ssid) { 'Wi-Fi "' + $on.ssid + '", ' } else { '' })
  $how = $(if ($keep) { 'its own fixed address kept, ' } else { 'DHCP, ' })
  Rn-Say ''
  if (-not (Test-RnOnlineOk $on $ad)) {
    $why = Get-RnOfflineWhy $on $ad
    if ($keep -and $on -and $on.link -and (-not $on.ip -or [string]$on.ip -like '169.254.*')) { $why = 'no usable address on this adapter' }
    if ($keep) { $why += '; it has its own fixed address - if it should be automatic, run "Restore Network.cmd" and type Y' }
    Rn-Say ('  settings are back to normal, but this PC is still offline: ' + $why) 'Red'
    Rn-Say ('NOT FIXED - run again or call. (' + $ad.name + ': ' + $why + ')') 'Red'
    $r = Write-RnReceipt ('NOT FIXED - run again or call (settings back to normal, still offline: ' + $why + ')') $ad
    if ($r) { Rn-Say ('Receipt: ' + $r) }
    return 8   # 8, not 7: Fix this site already uses 7 for its own stop
  }
  $gwt = $(if ($on.gw) { $(if ($on.gwPing) { ', router ' + $on.gw + ' answers' } else { ', router ' + $on.gw + ' does not answer ping (some routers never do)' }) } else { '' })
  Rn-Say ('DONE - network is back to normal and online (' + $ad.name + ': ' + $net + $how + 'address ' + $on.ip + $gwt + ', the internet answers through this adapter).') 'Green'
  $r = Write-RnReceipt ('DONE - network is back to normal and online (' + $net + $how + 'address ' + $on.ip + $(if ($on.gw) { ', router ' + $on.gw } else { '' }) + ')') $ad
  if ($r) { Rn-Say ('Receipt: ' + $r) }
  return 0
}

if ($MyInvocation.InvocationName -ne '.') {
  $code = 6
  try { $code = @(Invoke-RestoreNetwork)[-1] } catch { Rn-Say ('FAILED - Run again. Restore Network stopped: ' + $_.Exception.Message) 'Red'; try { [void](Write-RnReceipt ('FAILED - stopped: ' + $_.Exception.Message) $null) } catch {}; $code = 6 }
  exit $code
}
