<# Test-Fix2212Net.ps1 - WireIt Toolkit 2.2.12 (Nov 9 2026): Codex's 2.2.11 review, the Restore Network + WifiWatch findings.
   P1-3 Restore Network on an adapter with its OWN fixed address: its own before-snapshot, says so plainly, asks (Y), keeps it
        otherwise; the Toolkit's own temporary address (named in its record) still comes off (Codex reproduce.ps1 R2).
   P1-6 online = a real web request THROUGH the chosen adapter; DNS alone is not online; a router that refuses ping is not offline (R1).
   P1-7 WifiWatch: a running copy is waited for / stopped, the pause (pause file + task off) holds through the final online check,
        the no-change Wi-Fi path pauses too, a failed pause is never DONE, WifiWatch.ps1 respects a fresh pause file and ignores a stale one (R3).
   Moshe's rule: every change is tested for failing half-way, the wrong adapter/file and running twice.
   Runs against a simulated Windows (no real adapter is touched). Exit code = number of failed checks.
#>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2212net-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check($ok, [string]$name, [string]$more = '') {
  if ($ok -is [bool] -and $ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace "`n", "`n     ")) } }
}
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }

# ---------------- a simulated Windows for Restore Network (the 2.2.11 one, plus: own fixed addresses that work, DNS and the web
# separately, which adapter the web goes through, a WifiWatch copy that is RUNNING, the pause file, and the order of every step) ----
$rnFile = Join-Path $tk 'RestoreNetwork.ps1'
$simCode = @'
function New-SimAdapter([string]$name, [int]$ix, [bool]$wifi) {
  return @{ name = $name; ifIndex = $ix; desc = ($name + ' card'); wifi = $wifi; guid = ('g' + $ix); disabled = $false; cable = $true; dhcp = $true; coexist = 'disabled';
            active = (New-Object System.Collections.ArrayList); persistent = (New-Object System.Collections.ArrayList); proutes = (New-Object System.Collections.ArrayList); dnsStatic = $false; lease = ('192.168.4.' + (100 + $ix)); routerAnswers = $true;
            assoc = $true; joins = $true; joinSsid = 'Reichman Mesh'; profiles = @('Lizard', 'Reichman Mesh'); gwAnswers = $true; dnsOk = $true; httpOk = $true; httpVia = -1; onlineCalls = 0; reconnects = 0 }
}
$script:sim = @{ ads = @(); admin = $true; task = 'on'; running = 0; stopFails = $false; stopped = 0; pauseOn = $false; pauseFail = $false; order = (New-Object System.Collections.ArrayList);
                 calls = (New-Object System.Collections.ArrayList); fail = @{}; beforeAtChange = $null; elevate = 'deny' }
function Sim-Ad($ix) { foreach ($x in $script:sim.ads) { if ($x.ifIndex -eq [int]$ix) { return $x } }; return $null }
function Sim-BeforeExists { return [bool](@(Get-ChildItem (Join-Path $D 'receipts') -Filter 'RestoreNetwork-*-before.json' -ErrorAction SilentlyContinue).Count) }
$script:RnOps = {
  param($op, $a)
  if ($op -notin @('list', 'state', 'isadmin', 'sleep', 'wlan', 'taskrunning')) { [void]$script:sim.order.Add($op + $(if ($a.set) { ':' + $a.set } else { '' })) }
  if ($op -in @('enable', 'dhcp', 'removeaddr', 'removeroute', 'dnsreset', 'coexist')) {
    [void]$script:sim.calls.Add($op + ' ' + (($a.Keys | Sort-Object | Where-Object { $_ -in @('ip', 'store', 'gw', 'on', 'name') } | ForEach-Object { $_ + '=' + $a[$_] }) -join ' '))
    if ($null -eq $script:sim.beforeAtChange) { $script:sim.beforeAtChange = (Sim-BeforeExists) }
  }
  $key = $op + $(if ($a.store) { ':' + $a.store } else { '' })
  if ($script:sim.fail[$key]) { throw ('simulated: ' + $key + ' failed') }
  switch ($op) {
    'isadmin' { return $script:sim.admin }
    'list' { return @($script:sim.ads | ForEach-Object { [pscustomobject]@{ name = $_.name; ifIndex = $_.ifIndex; desc = $_.desc; disabled = $_.disabled; connected = ((-not $_.disabled) -and $_.cable -and ((-not $_.wifi) -or $_.assoc)); wifi = $_.wifi; guid = $_.guid } }) }
    'state' {
      $x = Sim-Ad $a.ifIndex
      $act = @($x.active | ForEach-Object { [pscustomobject]@{ ip = $_.ip; prefix = 24; origin = 'Manual' } })
      if ($x.dhcp -and -not $x.disabled -and $x.cable -and $x.routerAnswers) { $act += [pscustomobject]@{ ip = $x.lease; prefix = 22; origin = 'Dhcp' } }
      $rt = @($x.proutes | ForEach-Object { [pscustomobject]@{ gw = $_; store = 'PersistentStore'; manual = $true } }) + @($x.proutes | ForEach-Object { [pscustomobject]@{ gw = $_; store = 'ActiveStore'; manual = $true } })
      return [pscustomobject]@{ dhcp = $x.dhcp; coexist = $x.coexist; active = $act; persistent = @($x.persistent | ForEach-Object { [pscustomobject]@{ ip = $_.ip; prefix = 24; origin = 'Manual' } }); routes = $rt; dnsStatic = $x.dnsStatic; dnsServers = $(if ($x.dnsStatic) { @('10.1.10.1') } else { @() }) }
    }
    'enable' { (Sim-Ad $a.ifIndex).disabled = $false; return $true }
    'dhcp' { (Sim-Ad $a.ifIndex).dhcp = $true; return $true }
    'removeaddr' { $x = Sim-Ad $a.ifIndex; if ($a.store -eq 'PersistentStore') { $l = $x.persistent } else { $l = $x.active }; foreach ($e in @($l.ToArray() | Where-Object { $_.ip -eq $a.ip })) { $l.Remove($e) }; return $true }
    'removeroute' { $x = Sim-Ad $a.ifIndex; if ($a.store -eq 'PersistentStore') { $x.proutes.Remove($a.gw) }; return $true }
    'dnsreset' { (Sim-Ad $a.ifIndex).dnsStatic = $false; return $true }
    'coexist' { (Sim-Ad $a.ifIndex).coexist = $(if ($a.on) { 'enabled' } else { 'disabled' }); return $true }
    'reconnect' { $x = Sim-Ad $a.ifIndex; $x.reconnects++; if ($a.wifi) { if ($x.joins -and -not $x.disabled) { $x.assoc = $true }; return $x.profiles[0] }; return 'renew' }
    'wlan' { $x = Sim-Ad $a.ifIndex; $c = ($x.wifi -and -not $x.disabled -and $x.assoc); return [pscustomobject]@{ connected = $c; state = $(if ($c) { 'connected' } else { 'disconnected' }); ssid = $(if ($c) { $x.joinSsid } else { '' }); profile = $(if ($c) { $x.joinSsid } else { '' }) } }
    'online' {
      $x = Sim-Ad $a.ifIndex; $x.onlineCalls++
      [void]$script:sim.order.Add('online-while-paused=' + [bool]($script:sim.pauseOn))
      $link = ((-not $x.disabled) -and $x.cable -and ((-not $x.wifi) -or $x.assoc))
      $own = @($x.active | Where-Object { $_.ip -notlike '192.168.250.*' -and $_.ip -notlike '192.168.1.25*' })
      $ip = $(if ($link -and $x.dhcp -and $x.routerAnswers) { $x.lease } elseif ($link -and -not $x.dhcp -and $own.Count) { [string]$own[0].ip } elseif ($link -and $x.dhcp) { '169.254.10.20' } else { '' })
      $gw = $(if ($ip -and $ip -notlike '169.254.*') { $(if (-not $x.dhcp -and $x.proutes.Count) { [string]$x.proutes[0] } else { '192.168.4.1' }) } else { '' })
      $via = $(if ($x.httpVia -ge 0) { [int]$x.httpVia } else { [int]$x.ifIndex })
      $httpHere = [bool]($gw -and $x.httpOk -and $via -eq [int]$x.ifIndex)
      return [pscustomobject]@{ link = $link; ip = $ip; gw = $gw; gwPing = [bool]($gw -and $x.gwAnswers); dns = [bool]($gw -and $x.dnsOk); http = $httpHere; httpAny = [bool]($gw -and $x.httpOk); httpIf = $(if ($gw -and $x.httpOk) { $via } else { -1 }); ssid = $(if ($x.wifi -and $link) { $x.joinSsid } else { '' }); assoc = [bool]($x.wifi -and $link) }
    }
    'task' { if ($script:sim.task -eq 'none') { return 'none' }; if ($a.set) { $script:sim.task = $a.set }; return $script:sim.task }
    'taskrunning' { if ($script:sim.running -lt 0) { return $true }; if ($script:sim.running -gt 0) { $script:sim.running--; return $true }; return $false }
    'taskstop' { $script:sim.stopped++; if ($script:sim.stopFails) { throw 'simulated: access denied' }; $script:sim.running = 0; return $true }
    'pause' { if ($a.set -eq 'on') { if ($script:sim.pauseFail) { return $false }; $script:sim.pauseOn = $true; return $true }; $script:sim.pauseOn = $false; return $true }
    'sleep' { return $true }
    'elevate' { return $null }
  }
}
function Sim-Ext($x, [string]$ip, [string]$store) { if ($store -ne 'persistent') { [void]$x.active.Add(@{ ip = $ip }) }; if ($store -ne 'active') { [void]$x.persistent.Add(@{ ip = $ip }) } }
function Run-Rn { $script:RnLines.Clear(); $script:RnDone.Clear(); $script:sim.order.Clear(); $script:sim.calls.Clear(); $script:sim.beforeAtChange = $null; $script:Elevated = $false; $script:OutFile = ''; $c = @(Invoke-RestoreNetwork)[-1]; return [pscustomobject]@{ code = $c; said = (@($script:RnLines) -join "`n"); changed = @($script:RnDone); order = @($script:sim.order); calls = @($script:sim.calls); before = $script:sim.beforeAtChange } }
function Ad-View($x) { return @{ dhcp = $x.dhcp; act = @($x.active | ForEach-Object { $_.ip }); per = @($x.persistent | ForEach-Object { $_.ip }); routes = @($x.proutes); dns = $x.dnsStatic; disabled = $x.disabled } }
function Out-Result($h) { 'JSON=' + ($h | ConvertTo-Json -Compress -Depth 6) }
# Fix this site's record: a Toolkit alias 192.168.1.250 on ifIndex 12, the adapter was FIXED (dhcp false) before it
function Write-FsJournal([int]$ix, [bool]$dhcpBefore, [string]$ip) {
  $j = [ordered]@{ version = 2; written = (Get-Date -Format 's'); before = [ordered]@{ ifIndex = $ix; name = 'Ethernet'; dhcp = $dhcpBefore; coexist = 'disabled'; addrs = @(); gw = @() }; coexistChanged = $false; temps = @([ordered]@{ ip = $ip; prefix = 24; ifIndex = $ix }) }
  [IO.File]::WriteAllText((Join-Path $D 'Toolkit\fixsite-runs\_state\fixsite-temp-ips.json'), (ConvertTo-Json -Depth 5 -InputObject $j))
}
'@
function Rn-Driver([string]$name, [string]$body, [string]$extraParams = '') {
  $d = Join-Path $tmp $name; New-Item -ItemType Directory -Force -Path (Join-Path $d 'Toolkit\fixsite-runs\_state'), (Join-Path $d 'FixNVR\state') | Out-Null
  $pre = '$ErrorActionPreference = ''Continue''' + "`n" + '. ' + (Q $rnFile) + ' -ToolkitDir ' + (Q (Join-Path $d 'Toolkit')) + ' -FixNvrState ' + (Q (Join-Path $d 'FixNVR\state\temp-ips.json')) + ' -ReceiptDir ' + (Q (Join-Path $d 'receipts')) + ' -PauseFile ' + (Q (Join-Path $d 'wifiwatch.pause')) + ' -WaitSeconds 4 -OnlineSeconds 3 -Auto ' + $extraParams + "`n" + '$D = ' + (Q $d) + "`n" + $simCode + "`n"
  return (Invoke-Driver $name ($pre + $body))
}

try {
  # =====================================================================================
  Write-Host 'P1-3 (Codex R2): a static adapter + a record naming a SEPARATE Toolkit alias: only the alias comes off, 10.1.10.2 + gateway + DNS are kept'
  $o = Rn-Driver 'p13a' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $w = New-SimAdapter 'Wi-Fi 2' 7 $true; $script:sim.ads = @($e, $w)
$e.dhcp = $false; Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $e.dnsStatic = $true; Sim-Ext $e '192.168.1.250' 'both'
Write-FsJournal 12 $false '192.168.1.250'
$r1 = Run-Rn; $v1 = Ad-View $e; $wv = Ad-View $w
$bf = @(Get-ChildItem (Join-Path $D 'receipts') -Filter 'RestoreNetwork-*-before.json'); $bt = $(if ($bf.Count) { [IO.File]::ReadAllText($bf[0].FullName) } else { '' })
$rc = @(Get-ChildItem (Join-Path $D 'receipts') -Filter 'RestoreNetwork-*.txt' | Sort-Object Name); $rt = $(if ($rc.Count) { [IO.File]::ReadAllText($rc[-1].FullName) } else { '' })
$jl = @(Get-ChildItem (Join-Path $D 'Toolkit\fixsite-runs\_state') | ForEach-Object { $_.Name })
# running it twice: nothing more to change, the fixed address still kept
$r2 = Run-Rn; $v2 = Ad-View $e
Out-Result @{ c1 = $r1.code; s1 = $r1.said; calls1 = $r1.calls; before1 = $r1.before; v1 = $v1; wv = $wv; bt = $bt; rt = $rt; jl = $jl; c2 = $r2.code; s2 = $r2.said; calls2 = $r2.calls; v2 = $v2 }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'P13a driver ran' $o } else {
    Check (@($j.v1.act) -contains '10.1.10.2' -and @($j.v1.per) -contains '10.1.10.2' -and @($j.v1.routes) -contains '10.1.10.1' -and $j.v1.dns -and -not $j.v1.dhcp) 'P1-3 R2: the adapter''s OWN fixed address 10.1.10.2 (live + saved), its gateway 10.1.10.1 and its DNS are KEPT, DHCP stays off' (($j.calls1 -join "`n") + "`n" + $j.s1)
    Check (@($j.v1.act) -notcontains '192.168.1.250' -and @($j.v1.per) -notcontains '192.168.1.250') 'P1-3 R2: the Toolkit''s own alias 192.168.1.250 (named in its record) is taken off, both copies' ($j.calls1 -join "`n")
    Check (-not @($j.calls1 | Where-Object { $_ -match '^(dhcp|removeroute|dnsreset)' -or $_ -match 'ip=10\.1\.10\.2' }).Count) 'P1-3 R2: no DHCP switch, no gateway removal, no DNS reset, no removal of 10.1.10.2 is even attempted' ($j.calls1 -join "`n")
    Check ($j.s1 -match 'This adapter has a fixed address 10\.1\.10\.2 \(gateway 10\.1\.10\.1\)\. Restore Network will switch it to automatic \(DHCP\)\.' -and $j.s1 -match 'Its old settings are saved in .*-before\.json' -and $j.s1 -match 'Kept: the fixed address') 'P1-3 says it plainly: "This adapter has a fixed address X (gateway Y). Restore Network will switch it to automatic (DHCP). Its old settings are saved in <file>." and, with no yes, that it KEPT it' $j.s1
    Check ($j.before1 -eq $true -and $j.bt -match '10\.1\.10\.2' -and $j.bt -match '10\.1\.10\.1' -and $j.bt -match '"dhcp":\s*false') 'P1-3 its OWN before-snapshot (DHCP flag, addresses, gateway, DNS) exists BEFORE the first change' $j.bt
    Check ($j.c1 -eq 0 -and $j.s1 -match '(?m)^DONE' -and $j.s1 -match 'its own fixed address kept') 'P1-3 online through its own fixed address: DONE says the fixed address was kept (not "DHCP")' $j.s1
    Check (-not @($j.calls1 | Where-Object { $_ -match 'name=Wi-Fi' }).Count -and $j.wv.dhcp -and -not @($j.wv.act).Count) 'P1-3 wrong adapter: the other adapter (Wi-Fi 2) is not touched' ($j.calls1 -join "`n")
    Check (@($j.jl | Where-Object { $_ -match '\.restored-' }).Count -eq 1) 'P1-3 the Toolkit''s record is marked done (kept, renamed) once its alias is off' ($j.jl -join ', ')
    Check ($j.c2 -eq 0 -and -not @($j.calls2).Count -and @($j.v2.act) -contains '10.1.10.2' -and $j.s2 -match 'Nothing needed changing') 'P1-3 running it twice: the second run changes nothing and the fixed address is still kept' ($j.s2 + "`n" + ($j.calls2 -join "`n"))
  }

  Write-Host 'P1-3: the crew says Y -> the fixed adapter goes to DHCP (all of it); says no -> kept; the Toolkit turned DHCP off -> no question, DHCP back'
  $o = Rn-Driver 'p13b' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $script:sim.ads = @($e)
$e.dhcp = $false; Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $e.dnsStatic = $true
$script:RnAnswer = 'y'; $rY = Run-Rn; $vY = Ad-View $e
$e.dhcp = $false; Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $e.dnsStatic = $true
$script:RnAnswer = 'no'; $rN = Run-Rn; $vN = Ad-View $e
# Fix this site's record says the adapter WAS automatic, and it is now fixed: the Toolkit did it -> back to DHCP without asking
$e.active.Clear(); $e.persistent.Clear(); $e.proutes.Clear(); $e.dnsStatic = $false
$e.dhcp = $false; Sim-Ext $e '192.168.1.105' 'active'; Sim-Ext $e '192.168.1.250' 'active'; Write-FsJournal 12 $true '192.168.1.250'
$script:RnAnswer = $null; $rT = Run-Rn; $vT = Ad-View $e
# failing half-way: the crew said Y, the saved copy cannot be removed -> FAILED - Run again, never DONE
$e.dhcp = $false; Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $script:RnAnswer = 'Y'; $script:sim.fail['removeaddr:PersistentStore'] = $true
$rF = Run-Rn; $script:sim.fail.Remove('removeaddr:PersistentStore')
$rF2 = Run-Rn
Out-Result @{ cY = $rY.code; sY = $rY.said; vY = $vY; cN = $rN.code; sN = $rN.said; vN = $vN; cT = $rT.code; sT = $rT.said; vT = $vT; cF = $rF.code; sF = $rF.said; cF2 = $rF2.code; sF2 = $rF2.said }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'P13b driver ran' $o } else {
    Check ($j.cY -eq 0 -and $j.vY.dhcp -and -not @($j.vY.act).Count -and -not @($j.vY.per).Count -and -not @($j.vY.routes).Count -and -not $j.vY.dns -and $j.sY -match 'DHCP, address') 'P1-3 Y: DHCP on, the fixed address, gateway and DNS off, DONE (the 2.2.11 behaviour, now only with the crew''s yes)' $j.sY
    Check ($j.cN -eq 0 -and -not $j.vN.dhcp -and @($j.vN.act) -contains '10.1.10.2' -and $j.vN.dns -and $j.sN -match 'Kept') 'P1-3 not Y: nothing of the fixed setup is changed' $j.sN
    Check ($j.cT -eq 0 -and $j.vT.dhcp -and -not @($j.vT.act).Count -and $j.sT -notmatch 'This adapter has a fixed address') 'P1-3 the Toolkit''s record says it WAS automatic: DHCP back on, no question' $j.sT
    Check ($j.cF -eq 6 -and $j.sF -match '(?m)^FAILED - Run again' -and $j.sF -notmatch '(?m)^DONE') 'P1-3 failing half-way (a saved copy cannot be removed): FAILED - Run again, exit 6, never DONE' $j.sF
    Check ($j.cF2 -eq 0 -and $j.sF2 -match '(?m)^DONE') 'P1-3 ...and running it again finishes it: DONE' $j.sF2
  }

  Write-Host 'P1-3: the pick list does not flag an adapter that only has its own fixed address as "not normal"'
  $o = Rn-Driver 'p13c' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $w = New-SimAdapter 'Wi-Fi 2' 7 $true; $script:sim.ads = @($e, $w)
$e.dhcp = $false; Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1')
$x = @(Invoke-RnOp 'list'); $j0 = @(Get-RnJournals); $st = Invoke-RnOp 'state' @{ ifIndex = 12 }
$own = Get-RnOwnStatic $x[0] $st $j0; $bad = @(Test-RnNormal $x[0] $st $j0 ([bool]$own))
Write-FsJournal 12 $false '192.168.1.250'; Sim-Ext $e '192.168.1.250' 'active'; $j1 = @(Get-RnJournals); $st1 = Invoke-RnOp 'state' @{ ifIndex = 12 }
$own1 = Get-RnOwnStatic $x[0] $st1 $j1; $bad1 = @(Test-RnNormal $x[0] $st1 $j1 ([bool]$own1))
Out-Result @{ own = [bool]$own; bad = $bad; own1 = [bool]$own1; ownIps = @($own1.ips); bad1 = $bad1 }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'P13c driver ran' $o } else {
    Check ($j.own -and -not @($j.bad).Count) 'P1-3 its own fixed setup alone is "normal" (not suggested as the one to reset)' ($j.bad -join '; ')
    Check ($j.own1 -and @($j.ownIps) -notcontains '192.168.1.250' -and @($j.bad1 | Where-Object { $_ -match 'temporary address 192\.168\.1\.250' }).Count) 'P1-3 with a Toolkit alias on it: only the alias makes it "not normal"; the alias is never counted as its own address' ($j.bad1 -join '; ')
  }

  # =====================================================================================
  Write-Host 'P1-6 (Codex R1): online = the web through THIS adapter; DNS alone is not online; a router that refuses ping is not offline'
  $fn = [IO.File]::ReadAllText($rnFile)
  $ast = [Management.Automation.Language.Parser]::ParseFile($rnFile, [ref]$null, [ref]$null)
  $fns = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Test-RnOnlineOk', 'Test-RnHttpFrom') }, $true))
  $o = Invoke-Driver 'p16u' ((($fns | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" + @'
$ad = [pscustomobject]@{ ifIndex = 12 }
$dnsOnly = Test-RnOnlineOk ([pscustomobject]@{ link = $true; ip = '192.168.4.31'; gw = '192.168.4.1'; gwPing = $true; dns = $true; http = $false }) $ad
$noPing = Test-RnOnlineOk ([pscustomobject]@{ link = $true; ip = '192.168.4.31'; gw = '192.168.4.1'; gwPing = $false; dns = $true; http = $true; httpIf = 12 }) $ad
$other = Test-RnOnlineOk ([pscustomobject]@{ link = $true; ip = '192.168.4.31'; gw = '192.168.4.1'; gwPing = $true; dns = $true; http = $true; httpIf = 7 }) $ad
'JSON=' + (@{ dnsOnly = $dnsOnly; noPing = $noPing; other = $other } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'P16u driver ran' $o } else {
    Check (-not $j.dnsOnly) 'P1-6 R1: link/IP/gateway/ping/DNS all fine but the web request failed -> NOT online (2.2.11 said online)' $o
    Check ($j.noPing) 'P1-6 the router refuses ping but the web answers through this adapter -> online (2.2.11 said offline)' $o
    Check (-not $j.other) 'P1-6 the web answered, but through ANOTHER adapter -> NOT online for this one' $o
  }
  Check ($fn -match '\$c\.Client\.Bind\(' -and $fn -match "'online' \{[\s\S]*Test-RnHttpFrom \`$r\.ip") 'P1-6 the real check sends its web request from the chosen adapter''s own address (socket bound to it)'
  Check (-not ([regex]::Match($fn, "(?s)'online' \{.*?return \[pscustomobject\]\`$r").Value -match 'Resolve-DnsName')) 'P1-6 the real check no longer leans on Resolve-DnsName as a pass'
  # the bound request for real: a local web server answers; bound to an address this PC does not have = no answer; wrong page = no
  $py = $null; try { . (Join-Path $PSScriptRoot 'TestPython.ps1') } catch {}
  $pyExe = $null; foreach ($n in @('Get-TestPython', 'Find-TestPython')) { if (-not $pyExe -and (Get-Command $n -ErrorAction SilentlyContinue)) { try { $pyExe = & $n } catch {} } }
  if (-not $pyExe) { foreach ($n in @('python3', 'python')) { if (-not $pyExe) { $c = Get-Command $n -ErrorAction SilentlyContinue; if ($c) { $pyExe = $c.Source } } } }
  if ($pyExe) {
    $srv = Join-Path $tmp 'ncsi.py'; $portF = Join-Path $tmp 'ncsi.port'
    [IO.File]::WriteAllText($srv, @'
import http.server, socketserver, sys, threading, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'Microsoft Connect Test' if self.path == '/connecttest.txt' else b'nope'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = socketserver.TCPServer(('127.0.0.1', 0), H); open(sys.argv[1], 'w').write(str(s.server_address[1]))
threading.Timer(25, s.shutdown).start(); s.serve_forever()
'@)
    $pp = Start-Process -FilePath $pyExe -ArgumentList @($srv, $portF) -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $tmp 'ncsi.out') -RedirectStandardError (Join-Path $tmp 'ncsi.err')
    for ($i = 0; $i -lt 50 -and -not (Test-Path $portF); $i++) { Start-Sleep -Milliseconds 100 }
    $port = 0; try { $port = [int]([IO.File]::ReadAllText($portF).Trim()) } catch {}
    $o = Invoke-Driver 'p16h' ((($fns | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" + ('$port = ' + $port) + "`n" + @'
$good = Test-RnHttpFrom '127.0.0.1' ([Net.IPAddress]::Parse('127.0.0.1')) $port
$foreign = Test-RnHttpFrom '203.0.113.77' ([Net.IPAddress]::Parse('127.0.0.1')) $port
$closed = Test-RnHttpFrom '127.0.0.1' ([Net.IPAddress]::Parse('127.0.0.1')) 9
'JSON=' + (@{ good = $good; foreign = $foreign; closed = $closed } | ConvertTo-Json -Compress)
'@)
    try { $pp.Kill() } catch {}
    $j = Get-Json $o
    if (-not $j -or -not $port) { Check $false 'P16h driver ran' $o } else {
      Check ($j.good) 'P1-6 the bound web request reads Microsoft''s connect-test answer (real socket, local test server)' $o
      Check (-not $j.foreign) 'P1-6 bound to an address this PC does not have (wrong adapter) -> no answer, not online' $o
      Check (-not $j.closed) 'P1-6 nothing answering -> not online (no exception, just $false)' $o
    }
  } else { $script:deferred++; Write-Host 'DEFERRED P1-6 real bound web request (no python on this machine for the local test server)' }

  $o = Rn-Driver 'p16d' @'
$w = New-SimAdapter 'Wi-Fi 2' 7 $true; $e = New-SimAdapter 'Ethernet' 12 $false; $script:sim.ads = @($w, $e); $script:sim.task = 'none'
$w.httpOk = $false; $rA = Run-Rn
$w.httpOk = $true; $w.gwAnswers = $false; $rB = Run-Rn
$w.gwAnswers = $true; $w.httpVia = 12; $rC = Run-Rn
$w.httpVia = -1; $rD = Run-Rn; $rE = Run-Rn
Out-Result @{ cA = $rA.code; sA = $rA.said; cB = $rB.code; sB = $rB.said; cC = $rC.code; sC = $rC.said; cD = $rD.code; cE = $rE.code; sE = $rE.said }
'@ '-Adapter "Wi-Fi 2"'
  $j = Get-Json $o
  if (-not $j) { Check $false 'P16d driver ran' $o } else {
    Check ($j.cA -eq 8 -and $j.sA -match '(?m)^NOT FIXED' -and $j.sA -notmatch '(?m)^DONE' -and $j.sA -match 'DNS answer, but no web page') 'P1-6 Restore Network: DNS answers, the web does not -> NOT FIXED (exit 8) with the plain reason' $j.sA
    Check ($j.cB -eq 0 -and $j.sB -match '(?m)^DONE' -and $j.sB -match 'does not answer ping') 'P1-6 Restore Network: the router refuses ping, the web answers through this adapter -> DONE (the ping only noted)' $j.sB
    Check ($j.cC -eq 8 -and $j.sC -match 'ANOTHER adapter' -and $j.sC -notmatch '(?m)^DONE') 'P1-6 Restore Network: online only through the OTHER adapter (Ethernet) -> NOT FIXED "online through ANOTHER adapter", never DONE' $j.sC
    Check ($j.cD -eq 0 -and $j.cE -eq 0 -and $j.sE -match '(?m)^DONE') 'P1-6 running it twice when it is really online: DONE both times' $j.sE
  }

  # =====================================================================================
  Write-Host 'P1-7 (Codex R3): a WifiWatch copy that is ALREADY running is waited for / stopped; the pause holds through the final online check'
  $o = Rn-Driver 'p17a' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $script:sim.ads = @($e)
# A: something to change, a WifiWatch copy running that never ends by itself -> stopped (admin), then the work
$e.dhcp = $false; Sim-Ext $e '192.168.250.250' 'both'; Write-FsJournal 12 $true '192.168.250.250'; $script:sim.running = -1
$rA = Run-Rn; $stA = $script:sim.stopped; $taskA = $script:sim.task; $pA = $script:sim.pauseOn
# B: a copy that ends by itself after 3 looks -> waited for, not killed
$e.dhcp = $false; Sim-Ext $e '192.168.250.250' 'both'; Write-FsJournal 12 $true '192.168.250.250'; $script:sim.running = 3; $script:sim.stopped = 0
$rB = Run-Rn; $stB = $script:sim.stopped
# C: a running copy that cannot be stopped -> never DONE
$e.dhcp = $false; Sim-Ext $e '192.168.250.250' 'both'; Write-FsJournal 12 $true '192.168.250.250'; $script:sim.running = -1; $script:sim.stopFails = $true
$rC = Run-Rn; $taskC = $script:sim.task; $pC = $script:sim.pauseOn; $script:sim.running = 0; $script:sim.stopFails = $false
# D: the pause file cannot be written -> never DONE, the task still back on
$e.dhcp = $false; Sim-Ext $e '192.168.250.250' 'both'; Write-FsJournal 12 $true '192.168.250.250'; $script:sim.pauseFail = $true
$rD = Run-Rn; $taskD = $script:sim.task; $script:sim.pauseFail = $false
# E: running it again after that, all fine: DONE
$rE = Run-Rn
# F: failing half-way: the online check itself breaks -> the pause is still lifted and the task back on
$e.dhcp = $false; Sim-Ext $e '192.168.250.250' 'both'; $script:sim.fail['online'] = $true
$rF = Run-Rn; $taskF = $script:sim.task; $pF = $script:sim.pauseOn; $script:sim.fail.Remove('online')
# G: WifiWatch not installed on this PC (office PC / crew laptop): no pause needed, DONE
$e.dhcp = $false; Sim-Ext $e '192.168.250.250' 'both'; Write-FsJournal 12 $true '192.168.250.250'; $script:sim.task = 'none'; $rG = Run-Rn
Out-Result @{ cA = $rA.code; sA = $rA.said; oA = $rA.order; stA = $stA; taskA = $taskA; pA = $pA; cB = $rB.code; stB = $stB; cC = $rC.code; sC = $rC.said; taskC = $taskC; pC = $pC; cD = $rD.code; sD = $rD.said; taskD = $taskD; cE = $rE.code; cF = $rF.code; sF = $rF.said; taskF = $taskF; pF = $pF; cG = $rG.code; oG = $rG.order; sG = $rG.said }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'P17a driver ran' $o } else {
    $oa = @($j.oA); $iP = [array]::IndexOf($oa, 'pause:on'); $iOff = [array]::IndexOf($oa, 'task:off'); $iStop = [array]::IndexOf($oa, 'taskstop')
    $iFirst = -1; for ($i = 0; $i -lt $oa.Count; $i++) { if ($iFirst -lt 0 -and $oa[$i] -match '^(dhcp|removeaddr|enable|coexist|removeroute|dnsreset)') { $iFirst = $i } }
    $iOn = [array]::IndexOf($oa, 'task:on'); $iPOff = [array]::IndexOf($oa, 'pause:off'); $iLastOnline = -1; for ($i = 0; $i -lt $oa.Count; $i++) { if ($oa[$i] -eq 'online') { $iLastOnline = $i } }
    Check ($iP -ge 0 -and $iOff -gt $iP -and $iStop -gt $iOff -and $iFirst -gt $iStop -and $j.stA -ge 1) 'P1-7 R3: the pause file, the task off, the RUNNING copy stopped - all BEFORE the first change' ($oa -join ' > ')
    Check ($iLastOnline -gt $iFirst -and $iOn -gt $iLastOnline -and $iPOff -gt $iOn -and -not @($oa | Where-Object { $_ -eq 'online-while-paused=False' }).Count) 'P1-7 the pause holds through the FINAL online check; the task back on and the pause file off only after it' ($oa -join ' > ')
    Check ($j.cA -eq 0 -and $j.taskA -eq 'on' -and -not $j.pA) 'P1-7 ...DONE, and WifiWatch is back on with no pause left behind' $j.sA
    Check ($j.cB -eq 0 -and $j.stB -eq 0) 'P1-7 a copy that finishes by itself is waited for (not stopped)'
    Check ($j.cC -eq 6 -and $j.sC -match 'WifiWatch could NOT be paused' -and $j.sC -notmatch '(?m)^DONE' -and $j.taskC -eq 'on' -and -not $j.pC) 'P1-7 a running copy that cannot be stopped: FAILED - Run again (never DONE); task back on, pause file off' $j.sC
    Check ($j.cD -eq 6 -and $j.sD -match 'pause file could not be written' -and $j.sD -notmatch '(?m)^DONE' -and $j.taskD -eq 'on') 'P1-7 a failed pause is not DONE: FAILED - Run again; the task is back on' $j.sD
    Check ($j.cE -eq 0) 'P1-7 running it again after the failed pause: DONE'
    Check ($j.cF -ne 0 -and $j.sF -notmatch '(?m)^DONE' -and $j.taskF -eq 'on' -and -not $j.pF) 'P1-7 failing half-way (the check itself breaks): not DONE, the task back on, the pause file off (finally)' $j.sF
    Check ($j.cG -eq 0 -and -not @($j.oG | Where-Object { $_ -match '^(pause|task:)' }).Count) 'P1-7 wrong PC: WifiWatch not installed -> no pause file, no task change, DONE' (($j.oG -join ' > ') + "`n" + $j.sG)
  }

  Write-Host 'P1-7: the no-settings-change Wi-Fi reconnect path is paused too'
  $o = Rn-Driver 'p17b' @'
$w = New-SimAdapter 'Wi-Fi 2' 7 $true; $script:sim.ads = @($w); $w.assoc = $false
$rA = Run-Rn; $pA = $script:sim.pauseOn; $tA = $script:sim.task
# not admin (the crew login): the pause file still pauses it (the task cannot be switched off without admin)
$w.assoc = $false; $script:sim.admin = $false; $rB = Run-Rn; $tB = $script:sim.task
# not admin + the pause file cannot be written -> not DONE
$w.assoc = $false; $script:sim.pauseFail = $true; $rC = Run-Rn; $script:sim.pauseFail = $false
# twice, already on the Wi-Fi: no pause at all (nothing to do)
$rD = Run-Rn
Out-Result @{ cA = $rA.code; sA = $rA.said; oA = $rA.order; pA = $pA; tA = $tA; cB = $rB.code; oB = $rB.order; tB = $tB; cC = $rC.code; sC = $rC.said; cD = $rD.code; oD = $rD.order }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'P17b driver ran' $o } else {
    $oa = @($j.oA); $iP = [array]::IndexOf($oa, 'pause:on'); $iRc = [array]::IndexOf($oa, 'reconnect'); $iOn = [array]::IndexOf($oa, 'task:on'); $iPo = [array]::IndexOf($oa, 'pause:off')
    $iLast = -1; for ($i = 0; $i -lt $oa.Count; $i++) { if ($oa[$i] -eq 'online') { $iLast = $i } }
    Check ($j.cA -eq 0 -and $iP -ge 0 -and $iRc -gt $iP -and $iLast -gt $iRc -and $iOn -gt $iLast -and $iPo -gt $iOn -and $j.tA -eq 'on' -and -not $j.pA) 'P1-7 no settings changed, the Wi-Fi only rejoined: WifiWatch paused BEFORE the rejoin and through the online check, then back on' ($oa -join ' > ')
    Check ($j.cB -eq 0 -and @($j.oB) -contains 'pause:on' -and -not @($j.oB | Where-Object { $_ -match '^task:' }).Count -and $j.tB -eq 'on') 'P1-7 crew login (no admin): paused by the pause file, the task is not touched' (@($j.oB) -join ' > ')
    Check ($j.cC -eq 6 -and $j.sC -notmatch '(?m)^DONE') 'P1-7 no-change path, the pause file cannot be written: not DONE' $j.sC
    Check ($j.cD -eq 0 -and -not @($j.oD | Where-Object { $_ -match '^pause' }).Count) 'P1-7 running it twice (already on the Wi-Fi): nothing paused, nothing changed, DONE' (@($j.oD) -join ' > ')
  }

  # =====================================================================================
  Write-Host 'P1-7: WifiWatch.ps1 respects a fresh pause file (no reconnect, no adapter off) and ignores a stale one'
  $wwFile = Join-Path $repo 'wifiwatch\WifiWatch.ps1'
  $wd = Join-Path $tmp 'ww'; New-Item -ItemType Directory -Force -Path $wd | Out-Null; $pf = Join-Path $wd 'wifiwatch.pause'
  $rnFns = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Write-RnPauseFile', 'Remove-RnPauseFile') }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
  $o = Invoke-Driver 'ww2' ('$ErrorActionPreference = ''Continue''; $script:RnVersion = ''test''' + "`n" + $rnFns + "`n" + '. ' + (Q $wwFile) + ' -Dir ' + (Q $wd) + ' -PauseFile ' + (Q $pf) + "`n" + @'
$script:ww = @{ up = $true; calls = (New-Object System.Collections.ArrayList); pauseAfterDisable = $false }
$script:WwOps = { param($op, $a) if ($op -ne 'sleep') { [void]$script:ww.calls.Add($op) }
  switch ($op) {
    'disable' { $script:ww.up = $false; if ($script:ww.pauseAfterDisable) { [void](Write-RnPauseFile $PauseFile 10) }; return $true }
    'enable' { $script:ww.up = $true; return $true }
    'isup' { return $script:ww.up }
    default { return $true } } }
function U([int]$min) { return (Get-Date).ToUniversalTime().AddMinutes($min).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
# fresh pause written by Restore Network's OWN writer
$w1 = Write-RnPauseFile $PauseFile 10; $p1 = Test-WwPaused
$s2 = Invoke-WwStep 2 'Wi-Fi 2' 'Reichman Mesh'; $s3 = Invoke-WwStep 3 'Wi-Fi 2' 'Reichman Mesh'; $s13 = Invoke-WwStep 13 'Wi-Fi 2' 'Reichman Mesh'; $c1 = @($script:ww.calls)
# Restore Network finished: its own remover; WifiWatch acts again
$rm = Remove-RnPauseFile $PauseFile; $p2 = Test-WwPaused; $script:ww.calls.Clear()
$s2b = Invoke-WwStep 2 'Wi-Fi 2' 'Reichman Mesh'; $c2 = @($script:ww.calls); $script:ww.calls.Clear()
# stale (a crashed Restore Network): ignored
Set-Content -LiteralPath $PauseFile -Value ('until=' + (U -5)); $p3 = Test-WwPaused; $s3b = Invoke-WwStep 3 'Wi-Fi 2' 'Reichman Mesh'; $c3 = @($script:ww.calls); $script:ww.calls.Clear()
# too far ahead (a wrong clock / a hand-made file): ignored; garbage: ignored
Set-Content -LiteralPath $PauseFile -Value ('until=' + (U 600)); $p4 = Test-WwPaused
Set-Content -LiteralPath $PauseFile -Value 'hello'; $p5 = Test-WwPaused
# the pause lands while a cycle is half-way (adapter already off): the adapter is STILL switched back on, but no connect follows
Remove-Item -LiteralPath $PauseFile -Force; $script:ww.pauseAfterDisable = $true; $script:ww.calls.Clear()
Invoke-WwAdapterCycle 'Wi-Fi 2' 'Reichman Mesh'; $c6 = @($script:ww.calls); $u6 = $script:ww.up; $m6 = Test-Path $marker
'JSON=' + (@{ w1 = $w1; p1 = $p1; s2 = $s2; s3 = $s3; s13 = $s13; c1 = $c1; rm = $rm; p2 = $p2; s2b = $s2b; c2 = $c2; p3 = $p3; s3b = $s3b; c3 = $c3; p4 = $p4; p5 = $p5; c6 = $c6; u6 = $u6; m6 = $m6; log = [IO.File]::ReadAllText($log) } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'WW2 driver ran' $o } else {
    Check ($j.w1 -and $j.p1) 'P1-7 WifiWatch reads the pause file Restore Network writes (same format)' $o
    Check ($j.s2 -eq 'paused' -and $j.s3 -eq 'paused' -and $j.s13 -eq 'paused' -and -not @($j.c1).Count) 'P1-7 while it is fresh: no reconnect (check 2), no adapter off (check 3, 13) - not one Wi-Fi command' (@($j.c1) -join ', ')
    Check ($j.rm -and -not $j.p2 -and $j.s2b -eq 'reconnect' -and @($j.c2) -contains 'disconnect' -and @($j.c2) -contains 'connect') 'P1-7 once Restore Network removed it: WifiWatch reconnects again as before' (@($j.c2) -join ', ')
    Check (-not $j.p3 -and $j.s3b -eq 'cycle' -and @($j.c3) -contains 'disable' -and @($j.c3) -contains 'enable' -and $j.log -match 'pause file expired') 'P1-7 a STALE pause file (a crashed Restore Network) is ignored: WifiWatch acts, and logs why' (@($j.c3) -join ', ')
    Check (-not $j.p4 -and -not $j.p5) 'P1-7 a pause file 10 hours ahead, or an unreadable one, is ignored (it can never stop WifiWatch for good)' $j.log
    Check ($j.u6 -and -not $j.m6 -and @($j.c6) -contains 'enable' -and @($j.c6) -notcontains 'connect') 'P1-7 a pause that lands while the adapter is off: it is still switched back on (recovery), then no connect' (@($j.c6) -join ', ')
  }
  # the real script, run as the task runs it: a fresh pause file = it does nothing at all
  $wd2 = Join-Path $tmp 'ww-run'; New-Item -ItemType Directory -Force -Path $wd2 | Out-Null; $pf2 = Join-Path $wd2 'wifiwatch.pause'
  Set-Content -LiteralPath (Join-Path $wd2 'state.txt') -Value 2
  Set-Content -LiteralPath $pf2 -Value ('until=' + (Get-Date).ToUniversalTime().AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $null = & $exe -NoProfile -ExecutionPolicy Bypass -File $wwFile -Dir $wd2 -PauseFile $pf2 2>&1 | Out-String; $code1 = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  $log1 = ''; try { $log1 = [IO.File]::ReadAllText((Join-Path $wd2 'wifiwatch.log')) } catch {}
  $st1 = ([string](Get-Content -LiteralPath (Join-Path $wd2 'state.txt') -Raw)).Trim()
  Check ($code1 -eq 0 -and $log1 -match 'paused by Restore Network until .* - doing nothing' -and $st1 -eq '2') 'P1-7 the real WifiWatch.ps1 with a fresh pause file: logs "paused ... doing nothing", exits 0, its failure count untouched' $log1
  Set-Content -LiteralPath $pf2 -Value ('until=' + (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture))
  $ErrorActionPreference = 'Continue'
  try { $null = & $exe -NoProfile -ExecutionPolicy Bypass -File $wwFile -Dir $wd2 -PauseFile $pf2 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  $log2 = ''; try { $log2 = [IO.File]::ReadAllText((Join-Path $wd2 'wifiwatch.log')) } catch {}
  Check (([regex]::Matches($log2, 'doing nothing')).Count -eq 1 -and $log2 -match 'pause file expired') 'P1-7 the real WifiWatch.ps1 with an expired pause file: it goes on with its normal check' $log2
  # Restore Network's real pause-file writer and remover (the files WifiWatch reads)
  $o = Invoke-Driver 'rnpf' ('$script:RnVersion = ''test''' + "`n" + $rnFns + "`n" + ('$f = ' + (Q (Join-Path $tmp 'pf\sub\wifiwatch.pause'))) + "`n" + @'
$a = Write-RnPauseFile $f 10; $t = [IO.File]::ReadAllText($f); $b = Remove-RnPauseFile $f; $c = Test-Path $f; $d = Remove-RnPauseFile $f
'JSON=' + (@{ a = $a; t = $t; b = $b; c = $c; d = $d } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'RNPF driver ran' $o } else {
    Check ($j.a -and $j.t -match '(?m)^until=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ' -and $j.b -and -not $j.c -and $j.d) 'P1-7 Restore Network writes the pause file (folder made, read back), removes it, and removing it twice is fine' $j.t
  }
  $rnSrc = [IO.File]::ReadAllText($rnFile)
  Check ($rnSrc -match "'taskstop' \{ Stop-ScheduledTask" -and $rnSrc -match "'taskrunning' \{.*State -eq 'Running'") 'P1-7 (Windows side) a running WifiWatch is read from the task''s state and stopped with Stop-ScheduledTask'
} catch {
  $script:fail++; Write-Host ('FAIL the suite itself stopped: ' + $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')')
} finally {
  try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
$msg = ('Test-Fix2212Net: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
Write-Host $msg
exit $script:fail
