<#
 RestoreNetwork.ps1 - WireIt Toolkit 2.2.12: "Restore Network". ONE button: this PC's network adapter goes back to normal.
 Moshe Nov 9 2026 (add-on #3): the crew runs it, the laptop ends up as it was; running it twice is fine; a run that could not finish
 says "FAILED - Run again". No Tab and no AI inside; it runs on its own (Toolkit button, "Restore Network.cmd", or this file).

 What it does to the CHOSEN adapter (nothing else is touched):
   0. 2.2.12 (Codex P1-3): saves its OWN before-snapshot of the adapter (DHCP flag, addresses live+saved, routes, DNS) as
      receipts\RestoreNetwork-<time>-before.json BEFORE it changes anything, and says where it is
   1. pauses WifiWatch while it works (2.2.12, Codex P1-7): writes the pause file %ProgramData%\WireIt\wifiwatch.pause (WifiWatch.ps1
      reads it before every reset step and does nothing while it is fresh; an expired one is ignored, so a crashed run never
      stops the watcher for good), waits for / stops a copy that is already running, and keeps the pause until the FINAL online
      check is done; then the pause file comes off (try/finally). A pause that failed is never DONE.
      2.2.13 (Codex 2.2.12 #4): the task is NEVER switched off any more (a switched-off task stayed off for good when the run was
      killed). A task an earlier 2.2.12 run left OFF (its pause file still there) is switched back on (admin). At the end the
      task's REAL state is read again: "WifiWatch is back on" only when Windows says so, else "WifiWatch is OFF - turn it back on: ..."
   3b. 2.2.13 (Codex advice): the fixed-address switch is called "Reset chosen adapter to DHCP"; at the end of a run that changed the
      adapter it prints where the old settings are saved, and after a reset the old address / mask / gateway / DNS with plain steps
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
$script:RnVersion = '2.2.19'
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
$script:RnNotes = @()                                          # 2.2.19: things noted as not checked (said with the result)
if ($null -eq $script:RnOps) { $script:RnOps = $null }       # tests put a simulated Windows here

function Rn-Say([string]$t, [string]$c = '') {
  [void]$script:RnLines.Add($t)
  if ($OutFile) { try { Add-Content -LiteralPath $OutFile -Value $t -Encoding UTF8 } catch {} }
  if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t }
}
function Rn-Changed([string]$t) { [void]$script:RnDone.Add($t); Rn-Say ('  ' + $t) }

# ---------------- the Windows side (tests replace it with $script:RnOps) ----------------
# 2.2.19: $true when a failed Windows network query only means "there is none" (no address / no route), not a failed read
function Test-RnNoneFound($err) {
  try { if ([string]$err.CategoryInfo.Category -eq 'ObjectNotFound') { return $true } } catch {}
  return $false
}
function Invoke-RnOp([string]$op, $a = @{}) {
  if ($script:RnOps) { return (& $script:RnOps $op $a) }
  switch ($op) {
    'isadmin' { try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false } }
    'list' {
      $out = @()
      foreach ($n in @(Get-NetAdapter -Physical -ErrorAction Stop)) {   # 2.2.20 (class C): a list that fails is not "no adapter"
        if ([string]$n.InterfaceDescription -match '(?i)bluetooth|virtual|vpn|tap-|wan miniport') { continue }
        $wifi = ([string]$n.NdisPhysicalMedium -eq '9' -or [string]$n.NdisPhysicalMedium -match '802\.11|Native' -or [string]$n.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|wlan')
        $out += [pscustomobject]@{ name = [string]$n.Name; ifIndex = [int]$n.ifIndex; desc = [string]$n.InterfaceDescription; disabled = ([string]$n.Status -eq 'Disabled' -or [string]$n.AdminStatus -eq 'Down'); connected = ([string]$n.MediaConnectionState -eq 'Connected' -or [string]$n.Status -eq 'Up'); wifi = [bool]$wifi; guid = [string]$n.InterfaceGuid }
      }
      return $out
    }
    'state' {
      # 2.2.19 (Codex 2.2.18 F18/F08 twin): every query's success is tracked ('unread' names what could not be read); a failed query
      # is never read as "DHCP off" / "no fixed address" / "DNS automatic". "No matching object" from Windows is a real empty answer.
      $ix = [int]$a.ifIndex; $r = [ordered]@{ dhcp = $false; coexist = 'unknown'; active = @(); persistent = @(); routes = @(); dnsStatic = $false; dnsServers = @(); unread = @() }
      $un = @()
      $ipi = $null; try { $ipi = Get-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction Stop } catch { $un += 'the DHCP setting' }
      if (-not $ipi -and $un -notcontains 'the DHCP setting') { $un += 'the DHCP setting' }
      $r.dhcp = ($ipi -and [string]$ipi.Dhcp -eq 'Enabled')
      try { $t = (netsh interface ipv4 show interface ([string]$ix)) -join "`n"; $m = [regex]::Match($t, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)'); if ($m.Success) { $r.coexist = $m.Groups[1].Value.ToLower() } } catch {}
      try { $r.active = @(Get-NetIPAddress -InterfaceIndex $ix -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = [string]$_.PrefixOrigin } }) } catch { if (-not (Test-RnNoneFound $_)) { $un += 'the live addresses' } }
      try { $r.persistent = @(Get-NetIPAddress -InterfaceIndex $ix -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = 'Manual' } }) } catch { if (-not (Test-RnNoneFound $_)) { $un += 'the saved addresses' } }
      # a fixed router address is the one Windows SAVED (PersistentStore); a DHCP router address is never saved. Its live copy goes too.
      $pr = @(); try { $pr = @(Get-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore -ErrorAction Stop | ForEach-Object { [string]$_.NextHop }) } catch { if (-not (Test-RnNoneFound $_)) { $un += 'the saved router address' } }
      $rt = @($pr | ForEach-Object { [pscustomobject]@{ gw = $_; store = 'PersistentStore'; manual = $true } })
      try { $rt += @(Get-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ gw = [string]$_.NextHop; store = 'ActiveStore'; manual = ($pr -contains [string]$_.NextHop) } }) } catch { if (-not (Test-RnNoneFound $_)) { $un += 'the live router address' } }
      $r.routes = $rt
      $r.dnsServers = @(); try { $r.dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | ForEach-Object { [string]$_ }) } catch {}
      $g = [string]$a.guid
      if (-not $g) { $un += 'the DNS setting' }
      else { try { $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $g; $ip0 = Get-ItemProperty -LiteralPath $k -ErrorAction Stop; $ns = $(if ($ip0.PSObject.Properties['NameServer']) { [string]$ip0.NameServer } else { '' }); $r.dnsStatic = [bool]($ns.Trim()) } catch { $un += 'the DNS setting' } }
      $r.unread = @($un)
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
      # 2.2.13 (Codex 2.2.12 #4): a task Windows will not let this login read is 'unknown' (NOT 'none'); NEEDS WINDOWS CHECK
      $t = $null; try { $t = Get-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop } catch { if ([string]$_.CategoryInfo.Category -eq 'ObjectNotFound' -or [string]$_.FullyQualifiedErrorId -match '(?i)HRESULT 0x80070002') { return 'none' }; if ($a.set) { throw }; return 'unknown' }
      if (-not $t) { return 'none' }
      if ($a.set -eq 'off') { Disable-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop | Out-Null; try { Set-Content -LiteralPath $script:RnWifiWatchState -Value 0 } catch {}; return 'off' }
      if ($a.set -eq 'on') { Enable-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop | Out-Null; return 'on' }
      return $(if ([string]$t.State -eq 'Disabled') { 'off' } else { 'on' })
    }
    # 2.2.12 (Codex P1-7): Disable-ScheduledTask only stops FUTURE runs; a copy that is already running is waited for / stopped
    'taskrunning' { $t = Get-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction SilentlyContinue; return [bool]($t -and [string]$t.State -eq 'Running') }
    'taskstop' { Stop-ScheduledTask -TaskName $script:RnWifiWatchTask -ErrorAction Stop; return $true }
    # 2.2.13 (Codex 2.2.12 #4): $true when a pause file left on disk was written by Restore Network (the sign of a run that was stopped half-way)
    'pauseby' { return (Test-RnPauseByRn $script:RnPauseFile) }
    'pause' { if ($a.set -eq 'on') { return (Write-RnPauseFile $script:RnPauseFile $script:RnPauseMinutes) }; return (Remove-RnPauseFile $script:RnPauseFile) }
    'sleep' { Start-Sleep -Seconds ([int]$a.s); return $true }
    'elevate' {
      $exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
      $al = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Elevated -Auto -Adapter "' + $a.name + '" -OutFile "' + $a.out + '" -ToolkitDir "' + $ToolkitDir + '" -FixNvrState "' + $FixNvrState + '" -ReceiptDir "' + $ReceiptDir + '" -PauseFile "' + $script:RnPauseFile + '"' + $(if ($a.reset) { ' -ResetStatic' } else { '' })
      # 2.2.16: on the STANDARD Crew login RunAs asks for an administrator's name + password and this runs as that admin account (not Crew); UNVERIFIED, DEFERRED
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
# 2.2.13 (Codex 2.2.12 #4): $true when the pause file on disk was written by Restore Network (any version, any age)
function Test-RnPauseByRn([string]$file) {
  try { if (-not (Test-Path -LiteralPath $file)) { return $false }; return [bool]([IO.File]::ReadAllText($file) -match '(?m)^by=Restore Network') } catch { return $false }
}
# the plain steps to switch the WifiWatch task back on by hand
$script:RnWwOnSteps = 'Start menu > type "Task Scheduler" > open it > Task Scheduler Library > right-click "WireIt WifiWatch" > Enable (needs an admin login).'
# pauses WifiWatch. 2.2.13 (Codex 2.2.12 #4): the task is NEVER switched off any more (a switched-off task stays off for good when
# this run is killed or the power goes). The pause is ONLY the pause file, which WifiWatch.ps1 obeys while it is fresh and ignores once
# it has expired, so a killed run can never stop WifiWatch for good. A copy that is already running is waited for (and stopped).
# Recovery: an earlier 2.2.12 Restore Network that was killed left the task OFF and its pause file behind - that task is switched back on.
# returns { ok; why; file; needed; startState; recovered; recoverFailed } - ok is $true only when nothing of WifiWatch can act any more
function Start-RnPause([bool]$admin) {
  $r = [pscustomobject]@{ ok = $true; why = ''; taskOff = $false; file = $false; needed = $false; startState = 'none'; recovered = $false; recoverFailed = $false; leftByRn = $false }
  $ww = 'none'; try { $ww = [string](Invoke-RnOp 'task' @{ set = '' }) } catch { $ww = 'unknown' }
  if (-not $ww) { $ww = 'unknown' }
  $r.startState = $ww
  if ($ww -eq 'none') { return $r }   # WifiWatch is not installed on this PC: nothing to pause
  $r.needed = $true
  # read BEFORE this run writes its own pause file: was the one on disk left by an earlier Restore Network?
  $left = $false; try { $left = [bool](Invoke-RnOp 'pauseby') } catch {}
  $r.leftByRn = $left
  $f = $false; try { $f = [bool](Invoke-RnOp 'pause' @{ set = 'on' }) } catch {}
  $r.file = $f; if (-not $f) { $r.ok = $false; $r.why = 'its pause file could not be written' }
  if ($ww -eq 'off' -and $left) {
    if ($admin) {
      # switched on while this run's own fresh pause file holds it, so it does nothing until this run is finished
      try { [void](Invoke-RnOp 'task' @{ set = 'on' }); $r.recovered = $true; Rn-Say '  WifiWatch was left switched OFF by an earlier Restore Network that was stopped half-way - switched back on' 'Yellow' }
      catch { $r.recoverFailed = $true; Rn-Say ('  WifiWatch was left switched OFF by an earlier Restore Network and could NOT be switched back on: ' + $_.Exception.Message) 'Red' }
    }
  }
  # a copy that is running right now: it reads the pause file before its next step and ends; wait for it, then stop it
  $run = $false; try { $run = [bool](Invoke-RnOp 'taskrunning') } catch {}
  for ($i = 0; $run -and $i -lt 15; $i++) { [void](Invoke-RnOp 'sleep' @{ s = 2 }); try { $run = [bool](Invoke-RnOp 'taskrunning') } catch { $run = $false } }
  if ($run -and $admin) { try { [void](Invoke-RnOp 'taskstop'); Rn-Say '  a WifiWatch run that was still going was stopped' } catch {}; try { $run = [bool](Invoke-RnOp 'taskrunning') } catch {} }
  if ($run) { $r.ok = $false; $r.why = 'a WifiWatch run is still going and could not be stopped' }
  if ($r.ok) { Rn-Say '  WifiWatch paused while this works (and while the connection is checked)' } else { Rn-Say ('  WifiWatch could NOT be paused: ' + $r.why) 'Red' }
  return $r
}
# 2.2.13 (Codex 2.2.12 #4): a run that did NOT pause WifiWatch (nothing to do) still looks: an earlier 2.2.12 Restore Network that was
# killed left the task OFF and its pause file behind. Admin: switched back on (and that old pause file removed). No admin: said plainly.
function Repair-RnWifiWatchLeftOff([bool]$admin) {
  $ww = 'none'; try { $ww = [string](Invoke-RnOp 'task' @{ set = '' }) } catch { $ww = 'unknown' }
  if ($ww -ne 'off') { return '' }
  $left = $false; try { $left = [bool](Invoke-RnOp 'pauseby') } catch {}
  if ($left -and $admin) {
    try { [void](Invoke-RnOp 'task' @{ set = 'on' }) } catch { Rn-Say ('  WifiWatch was left switched OFF by an earlier Restore Network and could NOT be switched back on: ' + $_.Exception.Message) 'Red' }
    try { [void](Invoke-RnOp 'pause' @{ set = 'off' }) } catch {}
    $now = 'unknown'; try { $now = [string](Invoke-RnOp 'task' @{ set = '' }) } catch {}
    if ($now -eq 'on') { Rn-Say '  WifiWatch was left switched OFF by an earlier Restore Network that was stopped half-way - switched back on' 'Yellow'; return '' }
    $script:RnWwWarn = 'WifiWatch is OFF - turn it back on: ' + $script:RnWwOnSteps; Rn-Say ('  ' + $script:RnWwWarn) 'Red'
    return 'WifiWatch is OFF (it could not be switched back on)'
  }
  $script:RnWwWarn = 'WifiWatch is OFF - turn it back on: ' + $script:RnWwOnSteps; Rn-Say ('  ' + $script:RnWwWarn) 'Red'
  return ''
}
function Stop-RnPause($p) {
  # the pause file off, then the task's REAL state read again (2.2.13, Codex 2.2.12 #4) - "back on" is said only when Windows says so.
  # returns '' or what went wrong that this run caused or should have fixed (that makes the run FAILED - Run again).
  # A task that is OFF for another reason (not switched off by Restore Network) is said plainly, with the steps, in $script:RnWwWarn.
  $err = ''
  if (-not $p -or -not $p.needed) { return '' }
  $gone = $false; try { $gone = [bool](Invoke-RnOp 'pause' @{ set = 'off' }) } catch {}
  $now = 'unknown'; try { $now = [string](Invoke-RnOp 'task' @{ set = '' }) } catch { $now = 'unknown' }
  if (-not $now) { $now = 'unknown' }
  if ($now -eq 'on') {
    if ($gone) { Rn-Say '  WifiWatch is back on' }
    else { $err = 'WifiWatch''s pause file could not be removed (it runs again by itself within ' + $script:RnPauseMinutes + ' min)'; Rn-Say ('  ' + $err) 'Red' }
    return $err
  }
  if (-not $gone) { $err = 'WifiWatch''s pause file could not be removed (it runs again by itself within ' + $script:RnPauseMinutes + ' min)'; Rn-Say ('  ' + $err) 'Red' }
  if ($now -eq 'off') {
    $script:RnWwWarn = 'WifiWatch is OFF - turn it back on: ' + $script:RnWwOnSteps
    if ($p.recoverFailed -or $p.recovered -or $p.startState -eq 'on') { if (-not $err) { $err = 'WifiWatch is OFF (it could not be switched back on)' } }
  } elseif ($now -eq 'none') {
    if ($p.startState -ne 'none') { $script:RnWwWarn = 'WifiWatch''s task is GONE from this PC (it was there when this run started) - reinstall it: C:\WireIt\WifiWatch\install-task.ps1 (needs an admin login).' }
  } else {
    $script:RnWwWarn = 'WifiWatch: could not read whether its task is on (this login may not see it). Check it is on: ' + $script:RnWwOnSteps
  }
  if ($script:RnWwWarn) { Rn-Say ('  ' + $script:RnWwWarn) 'Red' }
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
  foreach ($j in @($journals | Where-Object { (Test-RnJournalFor $_ $ad) -and $_.readable })) { if ($j.dhcpBefore -eq $true) { return $null } }   # the Toolkit's record: it WAS automatic -> the Toolkit turned it off
  $tk = @(); foreach ($j in @($journals | Where-Object { Test-RnJournalFor $_ $ad })) { $tk += @($j.ips) }
  $ips = @(@($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' }) + @($st.persistent | Where-Object { $_ }) | ForEach-Object { [string]$_.ip } | Where-Object { $tk -notcontains $_ } | Select-Object -Unique)
  if (-not $ips.Count) { return $null }
  $gws = @($st.routes | Where-Object { $_ -and $_.manual } | ForEach-Object { [string]$_.gw } | Select-Object -Unique)
  return [pscustomobject]@{ ips = $ips; gws = $gws; text = (($ips -join ', ') + $(if ($gws.Count) { ' (gateway ' + ($gws -join ', ') + ')' } else { ' (no gateway)' })) }
}

# 2.2.20 (Codex 2.2.19 R08, Restore Network twin, class E): every Toolkit record Restore Network reads is checked for its full
# shape AND the TYPE of every value before anything in it is used (a "dhcp":"false" string is NOT false, it is damaged). Fix NVR's
# record (version 2: temps = list of { ip; ifIndex }; pc = { coexistence_before; firewall_rule; cleanup_task; ifIndex; alias; guid;
# dhcp; ip; gw }) and Fix this site's (version 2: before = { ifIndex; name; guid; dhcp; coexist; addrs; gw }; coexistChanged; temps).
# '' = usable, else the reason in plain words. A damaged record is quarantined (kept aside as .unreadable-<time>.json, which Fix NVR
# and Fix this site read as their durable block) and no change is made to this PC's network (see Get-RnJournalBlock).
function Test-RnIpv4([string]$s) { $p = [Net.IPAddress]::None; return ($s -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($s, [ref]$p)) }
function Test-RnJsonInt($v) {
  if ($null -eq $v -or $v -is [bool]) { return $false }
  if ($v -is [string]) { return ($v -match '^\d{1,9}$') }
  if ($v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte]) { return ([long]$v -ge 0) }
  return $false
}
function Test-RnOptIpv4($v) { return ($null -eq $v -or ($v -is [string] -and (-not $v -or (Test-RnIpv4 $v)))) }
function Test-RnOptString($v) { return ($null -eq $v -or $v -is [string]) }
function Get-RnClassicJournalProblem($o) {
  if ($o -isnot [pscustomobject]) { return 'it is not a record Fix NVR writes' }
  foreach ($k in 'version', 'temps', 'pc') { if (-not $o.PSObject.Properties[$k]) { return ('it has no "' + $k + '"') } }
  if (-not (Test-RnJsonInt $o.version) -or [int]$o.version -ne 2) { return ('its version (' + [string]$o.version + ') is not one this Toolkit knows') }
  $pc = $o.pc
  if ($pc -isnot [pscustomobject]) { return 'its PC part is missing' }
  foreach ($k in 'coexistence_before', 'firewall_rule', 'cleanup_task', 'ifIndex', 'alias', 'dhcp', 'ip', 'gw') { if (-not $pc.PSObject.Properties[$k]) { return ('its PC part has no "' + $k + '"') } }
  if ($pc.firewall_rule -isnot [bool]) { return 'its firewall_rule is not true/false' }
  if ($pc.cleanup_task -isnot [bool]) { return 'its cleanup_task is not true/false' }
  if ($null -ne $pc.dhcp -and $pc.dhcp -isnot [bool]) { return 'its DHCP setting is not true/false' }
  if ($null -ne $pc.ifIndex -and -not (Test-RnJsonInt $pc.ifIndex)) { return ('its adapter number ("' + [string]$pc.ifIndex + '") is not a number') }
  if ($null -ne $pc.coexistence_before -and ($pc.coexistence_before -isnot [string] -or ([string]$pc.coexistence_before).ToLower() -notin @('enabled', 'disabled'))) { return 'its coexistence setting is not readable' }
  if (-not (Test-RnOptString $pc.alias)) { return 'its adapter name is not text' }
  if ($pc.PSObject.Properties['guid'] -and -not (Test-RnOptString $pc.guid)) { return 'its adapter ID is not text' }
  if (-not (Test-RnOptIpv4 $pc.ip)) { return 'its old address is not a valid IP' }
  if (-not (Test-RnOptIpv4 $pc.gw)) { return 'its old router address is not a valid IP' }
  if ($null -ne $o.temps -and $o.temps -isnot [array] -and $o.temps -isnot [pscustomobject]) { return 'its address list is not a list' }
  $tl = @($o.temps | Where-Object { $null -ne $_ })
  foreach ($t in $tl) {
    if ($t -isnot [pscustomobject] -or -not $t.PSObject.Properties['ip'] -or -not (Test-RnIpv4 ([string]$t.ip))) { return 'an address in it is not a valid IP' }
    $tix = $(if ($t.PSObject.Properties['ifIndex']) { $t.ifIndex } else { $null })
    if ($null -ne $tix -and -not (Test-RnJsonInt $tix)) { return ('the adapter number of ' + [string]$t.ip + ' is not a number') }
    if ($null -eq $tix -and $null -eq $pc.ifIndex) { return ('it does not say which adapter ' + [string]$t.ip + ' is on') }
    if ($null -ne $tix -and $null -ne $pc.ifIndex -and [int]$tix -ne [int]$pc.ifIndex) { return ('the address ' + [string]$t.ip + ' is on another adapter than the one it saved') }
  }
  # 2.2.20 (R03): a record of a change must name the adapter it changed (number AND name or ID) and say what it was before
  $changed = ($tl.Count -or $null -ne $pc.coexistence_before -or $null -ne $pc.ifIndex)
  if ($changed) {
    if ($null -eq $pc.ifIndex) { return 'it changed this PC but does not say which adapter' }
    $gid = $(if ($pc.PSObject.Properties['guid']) { [string]$pc.guid } else { '' })
    if (-not [string]$pc.alias -and -not $gid) { return 'it does not name the adapter it changed (no name, no ID)' }
    if ($pc.dhcp -isnot [bool]) { return 'it does not say whether the adapter was automatic (DHCP) before' }
  }
  return ''
}
function Get-RnSiteJournalProblem($tj) {
  if ($null -eq $tj) { return 'it is empty' }
  if ($tj -is [array]) { $l0 = @($tj); if ($l0.Count -and -not @($l0 | Where-Object { -not ($_ -is [pscustomobject] -and (Test-RnIpv4 ([string]$_.ip)) -and (Test-RnJsonInt $_.ifIndex)) }).Count) { return 'it is the old 2.2.0 form, which does not name the adapter it changed' }; return 'it is a list that is not the old 2.2.0 form' }
  if ($tj -isnot [pscustomobject]) { return 'it is not a record Fix this site writes' }
  if (-not $tj.PSObject.Properties['version']) { if ($tj.PSObject.Properties['ip'] -and $tj.PSObject.Properties['ifIndex'] -and (Test-RnIpv4 ([string]$tj.ip)) -and (Test-RnJsonInt $tj.ifIndex)) { return 'it is the old 2.2.0 form, which does not name the adapter it changed' }; return 'it has no version (an old form that does not name the adapter it changed)' }
  if (-not (Test-RnJsonInt $tj.version) -or [int]$tj.version -ne 2) { return ('its version (' + [string]$tj.version + ') is not one this Toolkit knows') }
  foreach ($k in @('before', 'coexistChanged', 'temps')) { if (-not $tj.PSObject.Properties[$k]) { return ('it is missing ' + $k) } }
  if ($tj.coexistChanged -isnot [bool]) { return 'its coexistChanged is not true/false' }
  if ($null -ne $tj.temps -and $tj.temps -isnot [array] -and $tj.temps -isnot [pscustomobject]) { return 'its list of temporary addresses is not a list' }
  $tl = @($tj.temps | Where-Object { $null -ne $_ })
  $b = $tj.before
  # a record written before any change (no adapter yet, nothing added) is a real empty record
  if ($null -eq $b -or $b -isnot [pscustomobject]) { return 'it does not say how the adapter was before' }
  foreach ($k in @('ifIndex', 'name', 'dhcp', 'coexist', 'addrs', 'gw')) { if (-not $b.PSObject.Properties[$k]) { return ('it is missing before.' + $k) } }
  if (-not (Test-RnJsonInt $b.ifIndex)) { return 'its adapter number is not a number' }
  if ($b.name -isnot [string] -or -not $b.name) { return 'it does not name the adapter' }
  if ($b.PSObject.Properties['guid'] -and -not (Test-RnOptString $b.guid)) { return 'its adapter ID is not text' }
  if ($b.dhcp -isnot [bool]) { return 'its DHCP setting is not true/false' }
  if ($b.coexist -isnot [string] -or ([string]$b.coexist).ToLower() -notin @('enabled', 'disabled', 'unknown')) { return 'its coexistence setting is not readable' }
  if ($null -ne $b.addrs -and $b.addrs -isnot [array] -and $b.addrs -isnot [pscustomobject]) { return 'its list of the adapter''s own addresses is not a list' }
  foreach ($x in @($b.addrs | Where-Object { $null -ne $_ })) {
    if ($x -isnot [pscustomobject] -or -not (Test-RnIpv4 ([string]$x.ip))) { return 'one of its own addresses is not a valid IP' }
    if ($x.PSObject.Properties['prefix'] -and $null -ne $x.prefix -and (-not (Test-RnJsonInt $x.prefix) -or [int]$x.prefix -gt 32)) { return ('the prefix of ' + [string]$x.ip + ' is not 0-32') }
  }
  foreach ($g in @($b.gw)) { if ($null -ne $g -and ($g -isnot [string] -or ($g -and -not (Test-RnIpv4 $g)))) { return 'one of its routers is not a valid IP' } }
  if (-not $b.dhcp -and -not @(@($b.addrs) | Where-Object { $_ }).Count) { return 'it says the adapter had a fixed setup but lists no address' }
  foreach ($t in $tl) {
    if ($t -isnot [pscustomobject] -or -not (Test-RnIpv4 ([string]$t.ip)) -or -not $t.PSObject.Properties['ifIndex'] -or -not (Test-RnJsonInt $t.ifIndex)) { return 'a temporary address in it has no valid IP or adapter number' }
    if ([int]$t.ifIndex -ne [int]$b.ifIndex) { return ('the temporary address ' + [string]$t.ip + ' is on another adapter than the one it saved') }
  }
  return ''
}
# Fix NVR / Fix this site kept an unreadable record aside (or wrote down that one is unsolved): the earlier changes are not known
function Get-RnQuarantined {
  $l = @()
  foreach ($f in @($script:RnFixSiteState, $FixNvrState)) {
    if (-not $f) { continue }
    $dir = Split-Path -Parent $f; $base = [IO.Path]::GetFileNameWithoutExtension($f)
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
    $items = $null; try { $items = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop) } catch { $l += ('the folder ' + $dir + ' could not be listed'); continue }
    foreach ($x in $items) { if ($x.Name -like ($base + '.unreadable-*.json') -or $x.Name -eq ($base + '.recovery-needed.json')) { $l += $x.Name } }
  }
  return $l
}
function Get-RnJournals {
  $j = @()
  foreach ($f in @($script:RnFixSiteState, $FixNvrState)) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    $isSite = ($f -eq $script:RnFixSiteState)
    $o = $null; $bad = ''; $raw = ''
    try { $raw = [IO.File]::ReadAllText($f) } catch { $bad = 'could not be read' }
    if (-not $bad) { if (-not $raw.Trim()) { $bad = 'is empty' } else { try { $o = ConvertFrom-Json -InputObject $raw -ErrorAction Stop } catch { $bad = 'could not be read' } } }
    if (-not $bad) {
      $why = $(if ($isSite) { Get-RnSiteJournalProblem $o } else { Get-RnClassicJournalProblem $o })
      if ($why) { $bad = ('is damaged (' + $why + ')') }
    }
    $temps = @(); $ix = -1; $co = ''; $dhb = $null; $nm = ''; $gd = ''
    # nothing of a damaged record is used: no adapter, no addresses, no before-state
    if (-not $bad) {
      $temps = @($o.temps | Where-Object { $_ -and $_.ip })
      if ($isSite) {
        $b = $o.before
        if ($b) { $ix = [int]$b.ifIndex; $nm = [string]$b.name; if ($b.PSObject.Properties['guid']) { $gd = [string]$b.guid }; $dhb = [bool]$b.dhcp; $co = ConvertTo-RnCoexist $b.coexist }
      } else {
        # 2.2.20 (Codex 2.2.19 R03): Fix NVR writes pc.alias and pc.guid (2.2.19 read pc.name and never the ID, so the record matched
        # an adapter by its number alone)
        $pc = $o.pc
        if ($null -ne $pc.ifIndex) { $ix = [int]$pc.ifIndex; $nm = [string]$pc.alias; if ($pc.PSObject.Properties['guid']) { $gd = [string]$pc.guid }; $dhb = [bool]$pc.dhcp }
        if ($null -ne $pc.coexistence_before) { $co = ConvertTo-RnCoexist $pc.coexistence_before }
      }
    }
    $j += [pscustomobject]@{ file = $f; readable = (-not $bad); bad = $bad; ifIndex = $ix; name = $nm; guid = $gd; coexist = $co; dhcpBefore = $dhb; ips = @($temps | ForEach-Object { [string]$_.ip }) }
  }
  return $j
}
# 2.2.20 (R08 twin, class E): '' = the Toolkit's records may be used; else why NO change may be made to this PC's network. A damaged
# record is kept aside here (renamed .unreadable-<time>.json, the durable block Fix NVR / Fix this site clear only after their own
# checked recovery); one that could not be renamed stays where it is and blocks the same way at every run.
function Get-RnJournalBlock($journals) {
  $why = @()
  foreach ($jr in @($journals | Where-Object { -not $_.readable })) {
    $kept = Split-Path -Leaf $jr.file
    # a well-formed 2.2.0 record is one Fix this site still reads and puts back itself: left where it is (not kept aside as unreadable),
    # but Restore Network cannot tell which adapter it changed, so it changes nothing either
    if ([string]$jr.bad -like '*old 2.2.0 form*') { $why += ('the Toolkit''s record ' + $kept + ' ' + $jr.bad + ' (left in place: Fix this site puts it back at its next start)'); continue }
    $to = $jr.file -replace '\.json$', ('.unreadable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    try { Move-Item -LiteralPath $jr.file -Destination $to -Force -ErrorAction Stop; if ((Test-Path -LiteralPath $to) -and -not (Test-Path -LiteralPath $jr.file)) { $kept = Split-Path -Leaf $to } } catch {}
    $why += ('the Toolkit''s record ' + (Split-Path -Leaf $jr.file) + ' ' + $jr.bad + ' (kept as ' + $kept + ')')
  }
  foreach ($q in @(Get-RnQuarantined)) { if (-not @($why | Where-Object { $_ -like ('*' + $q + '*') }).Count) { $why += ('an earlier record of this PC''s network could not be read (kept as ' + $q + ')') } }
  if (-not $why.Count) { return '' }
  return (($why -join '; ') + ', so it is not known what that run changed on this PC')
}
# 2.2.19 (Codex 2.2.18 F05 twin): a record belongs to this adapter only when its number AND (when it names one) its adapter
# name / ID match - another adapter that took the number is not the one the record changed
# 2.2.19 (Codex 2.2.18 F05 twin): the chosen adapter read again - the one at its number with the SAME ID (name when no ID was
# read). $null = not found again (gone, or its number now belongs to another adapter, or the list could not be read)
# 2.2.20 (Codex 2.2.19 R03, class B): an adapter ID that was read is REQUIRED again - an adapter whose ID is now missing is not
# proof of the same adapter (2.2.19 fell back to the name). The name read at the start must match too.
function Test-RnSameGuid([string]$a, [string]$b) { return ([bool]$a -and [bool]$b -and $a.Trim('{}').ToLower() -eq $b.Trim('{}').ToLower()) }
function Get-RnAdapterAgain($ad) {
  if (-not $ad) { return $null }
  $l = $null; try { $l = @(Invoke-RnOp 'list') } catch { return $null }
  foreach ($x in @($l | Where-Object { $_ -and $_.ifIndex -eq $ad.ifIndex })) {
    if ([string]$ad.guid -and -not (Test-RnSameGuid ([string]$x.guid) ([string]$ad.guid))) { continue }
    if ([string]$ad.name -and [string]$x.name -ne [string]$ad.name) { continue }
    if (-not [string]$ad.guid -and -not [string]$ad.name) { continue }
    return $x
  }
  return $null
}
# 2.2.20 (R03): a record belongs to this adapter only when its number matches AND every identity it saved (ID, name) is matched by a
# value read now - a saved ID with no current ID is a MISMATCH, never a fall-back to the name; a record that names no adapter at all
# matches none (its addresses are never taken for the Toolkit's on an adapter it did not name)
function Test-RnJournalFor($j, $ad) {
  if (-not $j -or -not $ad -or $j.ifIndex -lt 0 -or $j.ifIndex -ne $ad.ifIndex) { return $false }
  if (-not [string]$j.guid -and -not [string]$j.name) { return $false }
  if ([string]$j.guid -and -not (Test-RnSameGuid ([string]$ad.guid) ([string]$j.guid))) { return $false }
  if ([string]$j.name -and [string]$ad.name -ne [string]$j.name) { return $false }
  return $true
}
# 2.2.20 (class B): a state read used to plan or to certify the result is bracketed by two identity checks of the same adapter;
# $null = it could not be shown to be this adapter's (Get-RnReadProblem then says NOT CHECKED)
function Read-RnStateFor($ad) {
  if (-not (Get-RnAdapterAgain $ad)) { return $null }
  $s = Invoke-RnOp 'state' @{ ifIndex = $ad.ifIndex; guid = $ad.guid }
  if (-not (Get-RnAdapterAgain $ad)) { return $null }
  return $s
}
# 2.2.19 (Codex 2.2.18 F18): '' when this state read is complete, else what could not be read
function Get-RnReadProblem($st) {
  if ($null -eq $st) { return 'the adapter''s settings could not be read' }
  if ($st.PSObject.Properties['unread'] -and @($st.unread | Where-Object { $_ }).Count) { return ((@($st.unread | Where-Object { $_ }) -join ', ') + ' could not be read') }
  return ''
}

function Get-RnPlan($ad, $st, $journals, [bool]$keep = $false) {
  # what has to change for this adapter to be "normal": DHCP on, no fixed address (live or saved), no fixed gateway, DNS automatic,
  # coexistence as it was (off unless the Toolkit's record says it was on), the adapter on
  # 2.2.12 (Codex P1-3): $keep = the adapter's OWN fixed setup stays (DHCP off, its address, gateway and DNS); only the
  # Toolkit's own temporary addresses (named in its records) and its coexistence change come off
  $p = New-Object System.Collections.ArrayList
  if ($ad.disabled) { [void]$p.Add([pscustomobject]@{ op = 'enable'; what = 'turn the adapter on' }) }
  $tk = @(); foreach ($j in @($journals | Where-Object { Test-RnJournalFor $_ $ad })) { $tk += @($j.ips) }
  if (-not $st.dhcp -and -not $keep) { [void]$p.Add([pscustomobject]@{ op = 'dhcp'; what = 'DHCP on (the router gives the address)' }) }
  foreach ($x in @($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' -and (-not $keep -or $tk -contains [string]$_.ip) })) { [void]$p.Add([pscustomobject]@{ op = 'removeaddr'; ip = [string]$x.ip; store = 'ActiveStore'; what = ('take off the ' + $(if ($tk -contains [string]$x.ip) { 'Toolkit''s temporary' } else { 'fixed' }) + ' address ' + $x.ip + ' (live copy)') }) }
  foreach ($x in @($st.persistent | Where-Object { $_ -and (-not $keep -or $tk -contains [string]$_.ip) })) { [void]$p.Add([pscustomobject]@{ op = 'removeaddr'; ip = [string]$x.ip; store = 'PersistentStore'; what = ('take off the ' + $(if ($tk -contains [string]$x.ip) { 'Toolkit''s temporary' } else { 'fixed' }) + ' address ' + $x.ip + ' (saved copy, it would come back after a restart)') }) }
  if (-not $keep) {
    foreach ($r in @($st.routes | Where-Object { $_ -and $_.manual })) { [void]$p.Add([pscustomobject]@{ op = 'removeroute'; gw = [string]$r.gw; store = [string]$r.store; what = ('take off the fixed router address ' + $r.gw + $(if ($r.store -eq 'PersistentStore') { ' (saved copy)' } else { ' (live copy)' })) }) }
    if ($st.dnsStatic) { [void]$p.Add([pscustomobject]@{ op = 'dnsreset'; what = 'DNS back to automatic' }) }
  }
  $want = Get-RnCoexistWant $ad $journals $keep
  # 2.2.19 (Codex 2.2.18 F18): an unknown setting is not "already right" - no blind write, and Test-RnNormal says NOT CHECKED
  if ($want -and (ConvertTo-RnCoexist $st.coexist) -and (ConvertTo-RnCoexist $st.coexist) -ne $want) { [void]$p.Add([pscustomobject]@{ op = 'coexist'; on = ($want -eq 'enabled'); what = ('DHCP+static coexistence back to ' + $want) }) }
  return $p.ToArray()
}
# coexistence as it should be: the Toolkit's record, else off. A kept fixed adapter with no Toolkit record: left as it is ('')
# 2.2.19 (class D): coexistence words normalized ('enabled'/'disabled'); '' = not known
function ConvertTo-RnCoexist($v) { $s = ([string]$v).Trim().ToLower(); if ($s -in @('enabled', 'on', 'true')) { return 'enabled' }; if ($s -in @('disabled', 'off', 'false')) { return 'disabled' }; return '' }
function Get-RnCoexistWant($ad, $journals, [bool]$keep) {
  $mine = @($journals | Where-Object { (Test-RnJournalFor $_ $ad) -and $_.coexist })
  if ($keep -and -not $mine.Count) { return '' }
  $want = 'disabled'; foreach ($j in $mine) { $want = $(if ($j.coexist -match '(?i)enabled') { 'enabled' } else { 'disabled' }) }
  return $want
}

function Test-RnNormal($ad, $st, $journals, [bool]$keep = $false) {
  # returns the list of things that are NOT normal (empty = normal); $keep (2.2.12, P1-3): the adapter's own fixed setup is normal
  $bad = @()
  # 2.2.19 (Codex 2.2.18 F18/F08 twin): a read that failed or is incomplete is NOT CHECKED, never "normal"
  $rp = Get-RnReadProblem $st
  if ($rp) { return @('NOT CHECKED: ' + $rp + ', so it is not known whether this adapter is back to normal') }
  # 2.2.19 (Codex 2.2.18 F09 twin): a Toolkit record that cannot be read or is damaged: what it changed is not known
  foreach ($j in @($journals | Where-Object { -not $_.readable })) { $bad += ('NOT CHECKED: the Toolkit''s record ' + (Split-Path -Leaf $j.file) + ' ' + $j.bad + ', so it is not known what that run changed on this PC - restart this PC, start Fix this site once (it checks every adapter and keeps the record aside), then run this again') }
  if ($ad.disabled) { $bad += 'the adapter is still turned off' }
  $tk = @(); foreach ($j in @($journals | Where-Object { Test-RnJournalFor $_ $ad })) { $tk += @($j.ips) }
  if (-not $keep) {
    if (-not $st.dhcp) { $bad += 'DHCP is not on' }
    foreach ($x in @($st.active | Where-Object { $_ -and [string]$_.origin -eq 'Manual' -and $tk -notcontains [string]$_.ip })) { $bad += ('the fixed address ' + $x.ip + ' is still on (live copy)') }
    foreach ($x in @($st.persistent | Where-Object { $_ -and $tk -notcontains [string]$_.ip })) { $bad += ('the fixed address ' + $x.ip + ' is still saved (it comes back after a restart)') }
    foreach ($r in @($st.routes | Where-Object { $_ -and $_.manual })) { $bad += ('the fixed router address ' + $r.gw + ' is still set') }
    if ($st.dnsStatic) { $bad += 'DNS is still set by hand' }
  }
  $want = Get-RnCoexistWant $ad $journals $keep
  $coNow = ConvertTo-RnCoexist $st.coexist
  if ($want -and $coNow -and $coNow -ne $want) { $bad += ('DHCP+static coexistence is ' + $coNow + ', should be ' + $want) }
  # 2.2.19 (Codex 2.2.18 F18): when the Toolkit's record says what it should be, a setting that cannot be read is NOT CHECKED - never
  # "back to normal" (2.2.18 skipped it and said DONE). Without a Toolkit record it is only noted (Restore Network's own policy).
  if ($want -and -not $coNow) {
    if (@($journals | Where-Object { Test-RnJournalFor $_ $ad }).Count) { $bad += ('NOT CHECKED: the DHCP+static coexistence setting could not be read (the Toolkit''s record says it should be ' + $want + ')') }
    elseif ($script:RnNotes -notcontains 'coexist') { $script:RnNotes += 'coexist' }
  }
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
    $l = @(('WireIt Toolkit ' + $script:RnVersion + ' - Restore Network receipt'), ('PC: ' + $env:COMPUTERNAME + '   user: ' + $env:USERNAME + '   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), ('Adapter: ' + $(if ($ad) { $ad.name } else { '(none)' })), ('Result: ' + $result), $(if ($script:RnWwWarn) { $script:RnWwWarn } else { '' }), 'Changed:')
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
  foreach ($j in @($journals)) { if (-not $sug -and $j.ifIndex -ge 0) { $sug = @($ads | Where-Object { Test-RnJournalFor $j $_ })[0] } }
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
  # 2.2.20 (Codex 2.2.19 R19/R20 class A twin): the rename is checked (new name there, old name gone) before it is said; a record
  # that could not be closed is returned as a problem (the run is then not DONE: the next Fix NVR / Fix this site would act on it)
  $probs = @()
  foreach ($j in @($journals | Where-Object { (Test-RnJournalFor $_ $ad) -and $_.readable })) {
    $to = $j.file -replace '\.json$', ('.restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    $err = ''
    try { Move-Item -LiteralPath $j.file -Destination $to -Force -ErrorAction Stop } catch { $err = $_.Exception.Message }
    if (-not $err -and (Test-Path -LiteralPath $to) -and -not (Test-Path -LiteralPath $j.file)) { Rn-Say ('  the Toolkit''s record ' + (Split-Path -Leaf $j.file) + ' is done (kept as ' + (Split-Path -Leaf $to) + ')') }
    else { $probs += ('the Toolkit''s record ' + (Split-Path -Leaf $j.file) + ' could not be marked done' + $(if ($err) { ' (' + $err + ')' } else { '' }) + ' - the next Fix NVR / Fix this site would act on it again') }
  }
  return $probs
}

# ================================ main ================================
# 2.2.12 (Codex P1-3): the crew decides about an adapter's OWN fixed address; returns $true = switch it to automatic
function Confirm-RnResetStatic($own, [string]$beforeFile) {
  if ($ResetStatic) { return $true }
  Rn-Say 'Reset chosen adapter to DHCP?' 'Yellow'   # 2.2.13 (Codex advice): the action says what it does
  Rn-Say ('This adapter has a fixed address ' + $own.text + '. Restore Network will switch it to automatic (DHCP).') 'Yellow'
  Rn-Say ('Its old settings are saved in ' + $(if ($beforeFile) { $beforeFile } else { '(the settings file could not be saved)' }) + '.')
  if (-not $beforeFile) { Rn-Say 'Because its old settings could not be saved, the fixed address is kept (nothing of it is changed).' 'Yellow'; return $false }
  $ans = $null
  if ($null -ne $script:RnAnswer) { $ans = [string]$script:RnAnswer }
  elseif ($Auto -or $Elevated) { $ans = '' }
  else { try { $ans = [string](Read-Host 'Type Y to reset this adapter to DHCP (automatic), or just Enter to keep the fixed address') } catch { $ans = '' } }
  if ($ans.Trim() -match '^(?i)y(es)?$') { return $true }
  Rn-Say ('  Kept: the fixed address ' + $own.text + ' and its DNS stay as they are. Only the Toolkit''s own temporary changes come off.') 'Yellow'
  if ($Auto -or $Elevated) { Rn-Say '  (To reset it to DHCP: run "Restore Network.cmd", pick this adapter and type Y.)' }
  return $false
}

function Invoke-RestoreNetwork {
  $script:RnWwWarn = ''; $script:RnResetStaticOk = $false; $script:RnBeforeFile = ''; $script:RnOwnBefore = $null; $script:RnStBefore = $null
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
  # 2.2.20 (Codex 2.2.19 R08 twin, class E): a damaged Toolkit record (or one Fix NVR / Fix this site already kept aside as unreadable)
  # means what an earlier run changed is not known: it is kept aside and NOTHING on this PC's network is changed
  $blk = Get-RnJournalBlock $journals
  if ($blk) {
    Rn-Say ('NOT CHECKED: ' + $blk + '. Nothing was changed on this PC''s network.') 'Red'
    Rn-Say 'FAILED - Run again after this: restart this PC, start the tool that made the record (Fix this site or Fix NVR) once - it checks every adapter and clears the record - then run Restore Network again.' 'Red'
    $rb = Write-RnReceipt ('FAILED - NOT CHECKED, nothing changed (' + $blk + ')') $ad; if ($rb) { Rn-Say ('Receipt: ' + $rb) }
    return 6
  }
  $st = Read-RnStateFor $ad
  # 2.2.19 (Codex 2.2.18 F18/F08 twin): settings that cannot be fully read are not planned from (a failed DHCP read is not "DHCP
  # off", a failed address read is not "no fixed address") and their before-copy would be incomplete: nothing is changed
  $rp0 = Get-RnReadProblem $st
  if ($rp0) {
    Rn-Say ('This adapter''s settings could not be fully read (' + $rp0 + '). Nothing was changed (NOT CHECKED).') 'Red'
    Rn-Say 'FAILED - Run again. If it fails twice, restart the PC.' 'Red'
    $r0 = Write-RnReceipt ('FAILED - NOT CHECKED, nothing changed (' + $rp0 + ')') $ad; if ($r0) { Rn-Say ('Receipt: ' + $r0) }
    return 6
  }
  # 2.2.12 (Codex P1-3): its OWN before-snapshot, BEFORE anything is changed, and where it is
  $beforeFile = Save-RnBefore $ad $st
  if ($beforeFile) { Rn-Say ('  this adapter''s settings before this run are saved in ' + $beforeFile) } else { Rn-Say '  the settings before this run could NOT be saved' 'Yellow' }
  $own = Get-RnOwnStatic $ad $st $journals
  $script:RnBeforeFile = $beforeFile; $script:RnOwnBefore = $own; $script:RnStBefore = $st
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
            $ad3 = Get-RnAdapterAgain $ad; if ($ad3) { $ad = $ad3; $st = Read-RnStateFor $ad } else { $st = $null }   # 2.2.20 (class B): not found again = NOT CHECKED
          }
        }
        $v = Get-RnVerdict $ad $st $journals $failed0 $keep
      } finally {
        $e0 = $(if ($pz) { Stop-RnPause $pz } else { Repair-RnWifiWatchLeftOff $admin0 }); if ($e0) { $failed0 += $e0 }
      }
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
      # 2.2.20 (class B): the adapter must be found again by its ID and name; the plan is made only from a complete read of it
      $st = $null; $adR = Get-RnAdapterAgain $ad; if ($adR) { $ad = $adR; $st = Read-RnStateFor $ad }
      $rp1 = Get-RnReadProblem $st
      if (-not $adR) { $failed += ('NOT CHECKED: the adapter "' + $ad.name + '" could not be found again (its number may now belong to another adapter) - nothing was changed'); $plan = @() }
      elseif ($rp1) { $failed += ('NOT CHECKED: ' + $rp1 + ' - nothing was changed'); $plan = @() }
      else { $plan = @(Get-RnPlan $ad $st $journals $keep) }
    }
    Rn-Say 'Putting it back:'
    # the adapter on and DHCP first, so the PC can get an address even if a later step fails
    foreach ($s in @($plan | Where-Object { $_.op -eq 'enable' }) + @($plan | Where-Object { $_.op -eq 'dhcp' }) + @($plan | Where-Object { $_.op -notin @('enable', 'dhcp') })) {
      try {
        # 2.2.19 (F05 twin): the adapter is identified again right before each change
        if (-not (Get-RnAdapterAgain $ad)) { throw ('the adapter "' + $ad.name + '" could not be found again (its number may now belong to another adapter), so this was not changed') }
        $a = @{ ifIndex = $ad.ifIndex; name = $ad.name; guid = $ad.guid }
        foreach ($k in @('ip', 'store', 'gw', 'on')) { if ($s.PSObject.Properties[$k]) { $a[$k] = $s.$k } }
        $ok = Invoke-RnOp $s.op $a
        if ($ok -eq $false) { throw 'Windows said no' }
        Rn-Changed $s.what
        if ($s.op -eq 'enable') { [void](Invoke-RnOp 'sleep' @{ s = 4 }) }
      } catch { $failed += ($s.what + ': ' + $_.Exception.Message); Rn-Say ('  NOT DONE: ' + $s.what + ' (' + $_.Exception.Message + ')') 'Red' }
    }
    # reconnect, then wait for the router's address
    # 2.2.20 (class B): the reconnect (a change) and every read that certifies the result need the same adapter, found again by ID + name
    $ad2 = Get-RnAdapterAgain $ad
    if ($ad2) { $ad = $ad2
      try { $rc = Invoke-RnOp 'reconnect' @{ ifIndex = $ad.ifIndex; name = $ad.name; wifi = $ad.wifi }; if ($ad.wifi) { Say-RnWifiJoined $ad } elseif (-not $keep) { Rn-Changed 'asked the router for a new address' } } catch { Rn-Say ('  reconnect did not work: ' + $_.Exception.Message) 'Yellow' }
    } else { $failed += ('NOT CHECKED: the adapter "' + $ad.name + '" could not be found again (its number may now belong to another adapter), so it was not asked to reconnect and its result is not known') }
    $st2 = $null
    for ($w = 0; $w -le [Math]::Max(0, $WaitSeconds); $w += 2) {
      $ad3 = Get-RnAdapterAgain $ad; if (-not $ad3) { $st2 = $null; break }
      $ad = $ad3; $st2 = Read-RnStateFor $ad
      if (-not $st2) { break }
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
  if (-not $bad.Count) {
    $on = Wait-RnOnline $ad
    # 2.2.20 (class B): the online answer certifies THIS adapter only if it is still the same one after the check
    if (-not (Get-RnAdapterAgain $ad)) { $bad += ('NOT CHECKED: the adapter "' + $ad.name + '" could not be found again after the connection check, so the result is not known'); $on = $null }
  }
  return [pscustomobject]@{ bad = $bad; on = $on; checked = [bool](-not $bad.Count) }
}

# after the last line: WifiWatch's state if it is not on (2.2.13, Codex 2.2.12 #4), then the saved settings and how to put them back
function Say-RnTail($ad) {
  if ($script:RnWwWarn) { Rn-Say $script:RnWwWarn 'Red' }
  foreach ($x in @(Get-RnRestoreLines $ad)) { Rn-Say $x }
}
# 2.2.13 (Codex advice on the DHCP reset): where the old settings are, and - when this run reset the adapter's OWN fixed address to
# DHCP - the old values in plain text with the steps a crew member can follow to put them back
function ConvertTo-RnMask([int]$prefix) {
  if ($prefix -lt 0 -or $prefix -gt 32) { return '' }
  $bits = ('1' * $prefix).PadRight(32, '0'); $o = @(); for ($i = 0; $i -lt 4; $i++) { $o += [string][Convert]::ToInt32($bits.Substring($i * 8, 8), 2) }
  return ($o -join '.')
}
function Get-RnRestoreLines($ad) {
  $l = @()
  if (-not $script:RnDone.Count) { return $l }
  $bf = [string]$script:RnBeforeFile
  $l += ('Settings from before this run are saved in: ' + $(if ($bf) { $bf } else { '(could not be saved)' }))
  $own = $script:RnOwnBefore; $st = $script:RnStBefore
  if (-not ($script:RnResetStaticOk -and $own)) { return $l }
  $l += 'This run did "Reset chosen adapter to DHCP". Its OLD fixed settings were:'
  foreach ($ip in @($own.ips)) {
    $pf = -1; foreach ($x in @(@($st.persistent) + @($st.active))) { if ($x -and [string]$x.ip -eq $ip -and $pf -lt 0) { try { $pf = [int]$x.prefix } catch {} } }
    $m = $(if ($pf -ge 0) { ConvertTo-RnMask $pf } else { '' })
    $l += ('  IP address ' + $ip + $(if ($m) { '   subnet mask ' + $m } else { '' }))
  }
  $l += ('  Gateway ' + $(if (@($own.gws).Count) { (@($own.gws) -join ', ') } else { '(none)' }))
  $dns = @(); if ($st -and $st.PSObject.Properties['dnsServers'] -and $st.dnsStatic) { $dns = @($st.dnsServers) }
  $l += ('  DNS ' + $(if ($dns.Count) { ($dns -join ', ') } else { '(automatic)' }))
  $l += ('To put them back (needs an admin login): Settings > Network & Internet > ' + $ad.name + ' > IP assignment > Edit > Manual > IPv4 on > type in the values above > Save.')
  return $l
}
function Complete-RnRun($ad, $v, $journals, $failed = @(), [bool]$keep = $false) {
  # the end: say DONE or FAILED - Run again / NOT FIXED, write the receipt. A step that failed (also: WifiWatch not paused / not back on) is never DONE
  $bad = @($v.bad) + @($failed | Where-Object { $_ })
  # 2.2.20 (class A): the Toolkit's records for this adapter are closed (and checked) BEFORE any DONE / NOT FIXED is said
  if (-not $bad.Count -and @($journals | Where-Object { Test-RnJournalFor $_ $ad }).Count) { $bad += @(Move-RnJournals $ad $journals) }
  if ($bad.Count) {
    Rn-Say ''
    foreach ($b in $bad) { Rn-Say ('  still wrong: ' + $b) 'Red' }
    Rn-Say 'FAILED - Run again. This PC''s network is NOT back to normal yet. If it fails twice, restart the PC.' 'Red'
    Say-RnTail $ad
    $r = Write-RnReceipt ('FAILED - Run again (' + ($bad -join '; ') + ')') $ad
    if ($r) { Rn-Say ('Receipt: ' + $r) }
    return 6
  }
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
    Say-RnTail $ad
    $r = Write-RnReceipt ('NOT FIXED - run again or call (settings back to normal, still offline: ' + $why + ')') $ad
    if ($r) { Rn-Say ('Receipt: ' + $r) }
    return 8   # 8, not 7: Fix this site already uses 7 for its own stop
  }
  if ($script:RnNotes -contains 'coexist') { Rn-Say '  note: the DHCP+static coexistence setting could not be read, so it was not checked (no Toolkit record names it)' 'Yellow' }
  $gwt = $(if ($on.gw) { $(if ($on.gwPing) { ', router ' + $on.gw + ' answers' } else { ', router ' + $on.gw + ' does not answer ping (some routers never do)' }) } else { '' })
  Rn-Say ('DONE - network is back to normal and online (' + $ad.name + ': ' + $net + $how + 'address ' + $on.ip + $gwt + ', the internet answers through this adapter).') 'Green'
  Say-RnTail $ad
  $r = Write-RnReceipt ('DONE - network is back to normal and online (' + $net + $how + 'address ' + $on.ip + $(if ($on.gw) { ', router ' + $on.gw } else { '' }) + ')') $ad
  if ($r) { Rn-Say ('Receipt: ' + $r) }
  return 0
}

if ($MyInvocation.InvocationName -ne '.') {
  $code = 6
  try { $code = @(Invoke-RestoreNetwork)[-1] } catch { Rn-Say ('FAILED - Run again. Restore Network stopped: ' + $_.Exception.Message) 'Red'; try { [void](Write-RnReceipt ('FAILED - stopped: ' + $_.Exception.Message) $null) } catch {}; $code = 6 }
  exit $code
}
