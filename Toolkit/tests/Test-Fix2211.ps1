<# Test-Fix2211.ps1 - tests for WireIt Toolkit 2.2.11 (Nov 9 2026): Restore Network (add-on #3), the WifiWatch adapter fix,
   Fix NVR with no usable config.json (Codex R14 / F16), and Run-AllTests never counting a deferred check as a pass (Codex R17).
   Moshe's rule: every change is tested for failing half-way, the wrong site (here: the wrong adapter / another tool's file) and
   running twice. Restore Network and WifiWatch run against a simulated Windows (no real adapter is touched here).
   Round 2 (Nov 9 2026, Sitebox 2): the real Wi-Fi name after a reconnect (bug 1) and DONE only when really online (bug 2).
   NEEDS WINDOWS CHECK: the real Windows commands behind Restore Network (run it once on a real adapter). Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2211-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace "`n", "`n     ")) } }
}
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function Get-FnText([string]$file, [string[]]$only = @()) {
  $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  $fns = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
  if ($only.Count) { $fns = @($fns | Where-Object { $only -contains $_.Name }) }
  return (($fns | ForEach-Object { $_.Extent.Text }) -join "`n")
}

# ---------------- a simulated Windows for Restore Network ----------------
$rnFile = Join-Path $tk 'RestoreNetwork.ps1'
$simCode = @'
function New-SimAdapter([string]$name, [int]$ix, [bool]$wifi) {
  return @{ name = $name; ifIndex = $ix; desc = ($name + ' card'); wifi = $wifi; guid = ('g' + $ix); disabled = $false; cable = $true; dhcp = $true; coexist = 'disabled';
            active = (New-Object System.Collections.ArrayList); persistent = (New-Object System.Collections.ArrayList); proutes = (New-Object System.Collections.ArrayList); dnsStatic = $false; lease = ('192.168.4.' + (100 + $ix)); routerAnswers = $true;
            assoc = $true; joins = $true; joinSsid = 'Reichman Mesh'; profiles = @('Lizard', 'Reichman Mesh'); gwAnswers = $true; internet = $true; onlineAfter = 0; onlineCalls = 0; reconnects = 0 }
}
$script:sim = @{ ads = @(); admin = $true; task = 'on'; taskSets = (New-Object System.Collections.ArrayList); calls = (New-Object System.Collections.ArrayList); fail = @{}; elevate = 'deny'; elevated = 0 }
function Sim-Ad($ix) { foreach ($x in $script:sim.ads) { if ($x.ifIndex -eq [int]$ix) { return $x } }; return $null }
$script:RnOps = {
  param($op, $a)
  # 2.2.13 (Codex 2.2.12 #4): 'pauseby' is a read (who wrote the pause file), not a change
  if ($op -notin @('list', 'state', 'isadmin', 'sleep', 'task', 'wlan', 'online', 'pause', 'pauseby', 'taskrunning')) { [void]$script:sim.calls.Add($op + ' ' + (($a.Keys | Sort-Object | Where-Object { $_ -in @('ip', 'store', 'gw', 'on', 'name') } | ForEach-Object { $_ + '=' + $a[$_] }) -join ' ')) }
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
      return [pscustomobject]@{ dhcp = $x.dhcp; coexist = $x.coexist; active = $act; persistent = @($x.persistent | ForEach-Object { [pscustomobject]@{ ip = $_.ip; prefix = 24; origin = 'Manual' } }); routes = $rt; dnsStatic = $x.dnsStatic }
    }
    'enable' { (Sim-Ad $a.ifIndex).disabled = $false; return $true }
    'dhcp' { (Sim-Ad $a.ifIndex).dhcp = $true; return $true }
    'removeaddr' { $x = Sim-Ad $a.ifIndex; if ($a.store -eq 'PersistentStore') { $l = $x.persistent } else { $l = $x.active }; foreach ($e in @($l.ToArray() | Where-Object { $_.ip -eq $a.ip })) { $l.Remove($e) }; return $true }
    'removeroute' { $x = Sim-Ad $a.ifIndex; if ($a.store -eq 'PersistentStore') { $x.proutes.Remove($a.gw) }; return $true }
    'dnsreset' { (Sim-Ad $a.ifIndex).dnsStatic = $false; return $true }
    'coexist' { (Sim-Ad $a.ifIndex).coexist = $(if ($a.on) { 'enabled' } else { 'disabled' }); return $true }
    'reconnect' {
      # like Windows on Sitebox 2: the code may ASK for the first saved profile ("Lizard"); what it really joins is joinSsid
      $x = Sim-Ad $a.ifIndex; $x.reconnects++
      if ($a.wifi) { if ($x.joins -and -not $x.disabled) { $x.assoc = $true }; return $x.profiles[0] }
      return 'renew'
    }
    'wlan' { $x = Sim-Ad $a.ifIndex; $c = ($x.wifi -and -not $x.disabled -and $x.assoc); return [pscustomobject]@{ connected = $c; state = $(if ($c) { 'connected' } else { 'disconnected' }); ssid = $(if ($c) { $x.joinSsid } else { '' }); profile = $(if ($c) { $x.joinSsid } else { '' }) } }
    'online' {
      $x = Sim-Ad $a.ifIndex; $x.onlineCalls++
      $link = ((-not $x.disabled) -and $x.cable -and ((-not $x.wifi) -or $x.assoc))
      $ip = $(if ($link -and $x.dhcp -and $x.routerAnswers) { $x.lease } elseif ($link -and $x.dhcp) { '169.254.10.20' } else { '' })
      $up = ($x.onlineCalls -gt $x.onlineAfter)
      $gw = $(if ($ip -and $ip -notlike '169.254.*') { '192.168.4.1' } else { '' })
      return [pscustomobject]@{ link = $link; ip = $ip; gw = $gw; gwPing = [bool]($gw -and $x.gwAnswers -and $up); dns = [bool]($gw -and $x.internet -and $up); http = [bool]($gw -and $x.internet -and $up); ssid = $(if ($x.wifi -and $link) { $x.joinSsid } else { '' }); assoc = [bool]($x.wifi -and $link) }
    }
    'task' { if ($script:sim.task -eq 'none') { return 'none' }; if ($a.set) { [void]$script:sim.taskSets.Add($a.set); $script:sim.task = $a.set }; return $script:sim.task }
    'taskrunning' { return $false }   # 2.2.12 (P1-7): no WifiWatch copy running (Test-Fix2212Net.ps1 simulates a running one)
    'taskstop' { return $true }
    'pause' { return $true }
    'sleep' { return $true }
    'elevate' {
      $script:sim.elevated++
      if ($script:sim.elevate -eq 'deny') { return $null }
      # "Windows" runs the admin copy: same simulated PC, with admin rights
      $script:sim.admin = $true; $script:Elevated = $true; $script:Adapter = $a.name; $script:Auto = $true; $script:OutFile = $a.out
      $c = @(Invoke-RestoreNetwork)[-1]
      return [pscustomobject]@{ HasExited = $true; ExitCode = $c }
    }
  }
}
function Sim-Ext([string]$ip, [string]$store) { $x = $script:sim.ads[0]; if ($store -ne 'persistent') { [void]$x.active.Add(@{ ip = $ip }) }; if ($store -ne 'active') { [void]$x.persistent.Add(@{ ip = $ip }) } }
function Run-Rn { $script:RnLines.Clear(); $script:RnDone.Clear(); $script:Elevated = $false; $script:OutFile = ''; $c = @(Invoke-RestoreNetwork)[-1]; return [pscustomobject]@{ code = $c; said = (@($script:RnLines) -join "`n"); changed = @($script:RnDone) } }
function Out-Result($h) { 'JSON=' + ($h | ConvertTo-Json -Compress -Depth 6) }
'@
function Rn-Driver([string]$name, [string]$body, [string]$extraParams = '') {
  $d = Join-Path $tmp $name; New-Item -ItemType Directory -Force -Path (Join-Path $d 'Toolkit\fixsite-runs\_state'), (Join-Path $d 'FixNVR\state') | Out-Null
  $pre = '$ErrorActionPreference = ''Continue''' + "`n" + '. ' + (Q $rnFile) + ' -ToolkitDir ' + (Q (Join-Path $d 'Toolkit')) + ' -FixNvrState ' + (Q (Join-Path $d 'FixNVR\state\temp-ips.json')) + ' -ReceiptDir ' + (Q (Join-Path $d 'receipts')) + ' -WaitSeconds 4 -Auto ' + $extraParams + "`n" + $simCode + "`n" + '$D = ' + (Q $d) + "`n"
  return (Invoke-Driver $name ($pre + $body))
}

try {
  # =====================================================================================
  Write-Host 'Restore Network (#3): the chosen adapter back to DHCP, every extra address off (live AND saved copy), WifiWatch always back on'
  $o = Rn-Driver 'rn1' @'
$script:sim.ads = @((New-SimAdapter 'Ethernet' 12 $false), (New-SimAdapter 'Wi-Fi 2' 7 $true))
$e = $script:sim.ads[0]; $e.coexist = 'enabled'; Sim-Ext '192.168.250.250' 'both'
$r1 = Run-Rn
$rcpt = @(Get-ChildItem (Join-Path $D 'receipts') -Filter 'RestoreNetwork-*.txt' -ErrorAction SilentlyContinue)
$rtext = $(if ($rcpt.Count) { [IO.File]::ReadAllText($rcpt[0].FullName) } else { '' })
$calls1 = @($script:sim.calls); $script:sim.calls.Clear(); $script:sim.taskSets.Clear()
$r2 = Run-Rn
Out-Result @{ c1 = $r1.code; s1 = $r1.said; ch1 = $r1.changed; calls1 = $calls1; act = @($e.active | % { $_.ip }); per = @($e.persistent | % { $_.ip }); co = $e.coexist; dhcp = $e.dhcp; task = $script:sim.task; rcpt = $rcpt.Count; rtext = $rtext;
  c2 = $r2.code; s2 = $r2.said; calls2 = @($script:sim.calls); sets2 = @($script:sim.taskSets); wifiCalls = @($calls1 | ? { $_ -match 'name=Wi-Fi' }) }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN driver ran' $o } else {
    Check ($j.c1 -eq 0 -and $j.s1 -match 'DONE - network is back to normal') 'RN the extra address is taken off and it says "DONE - network is back to normal" (exit 0)' $j.s1
    Check (-not @($j.act).Count -and -not @($j.per).Count) 'RN 192.168.250.250 is gone from BOTH the live and the saved (persistent) copy - netsh adds it persistently' ($j.calls1 -join "`n")
    Check (@($j.calls1 | ? { $_ -match 'removeaddr .*store=PersistentStore' }).Count -eq 1 -and @($j.calls1 | ? { $_ -match 'removeaddr .*store=ActiveStore' }).Count -eq 1) 'RN ...one removal for each copy' ($j.calls1 -join "`n")
    Check ($j.co -eq 'disabled' -and $j.dhcp) 'RN DHCP stays on and DHCP+static coexistence goes back to off'
    Check ($j.task -eq 'on') 'RN WifiWatch is switched back on at the end'
    Check (-not @($j.wifiCalls).Count) 'RN the other adapter (Wi-Fi 2) is not touched'
    Check ($j.rcpt -eq 1 -and $j.rtext -match 'Result: DONE' -and $j.rtext -match '192\.168\.250\.250' -and $j.rtext -match 'saved copy') 'RN a plain-text receipt is saved: result + what was changed (job receipt #4)' $j.rtext
    $rl = @(([string]$j.rtext) -split "`r?`n")
    Check ($rl.Count -gt 6 -and $rl[0] -match '^WireIt Toolkit [0-9.]+ - Restore Network receipt$' -and $rl[1] -match '^PC: ' -and $rl[2] -match '^Adapter: ' -and $rl[3] -match '^Result: ') 'RN receipt: one fact per line (title, PC, adapter, result) - found on the Office PC, the first four were run together on one line' ($rl[0..3] -join ' | ')
    Check ($j.c2 -eq 0 -and $j.s2 -match 'Nothing needed changing' -and $j.s2 -match 'DONE - network is back to normal') 'RN running it twice: the second run changes nothing and still says DONE' $j.s2
    Check (-not @($j.calls2).Count -and -not @($j.sets2).Count) 'RN ...and the second run makes no change at all (not even WifiWatch is paused)' ($j.calls2 -join "`n")
  }

  # =====================================================================================
  Write-Host 'Restore Network: a static adapter (fixed address + gateway + DNS by hand) goes to DHCP; a disabled Wi-Fi adapter is switched on'
  $o = Rn-Driver 'rn2' @'
$script:sim.ads = @((New-SimAdapter 'Ethernet' 12 $false))
$e = $script:sim.ads[0]; $e.dhcp = $false; Sim-Ext '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $e.dnsStatic = $true
$script:RnAnswer = 'Y'   # 2.2.12 (Codex P1-3): an adapter's OWN fixed address is switched to DHCP only when the crew says yes (Test-Fix2212Net.ps1 covers "no")
$r1 = Run-Rn
$w = New-SimAdapter 'Wi-Fi 2' 7 $true; $w.disabled = $true; $script:sim.ads = @($w)
$script:sim.calls.Clear(); $r2 = Run-Rn
Out-Result @{ c1 = $r1.code; s1 = $r1.said; e = @{ dhcp = $e.dhcp; act = @($e.active).Count; per = @($e.persistent).Count; routes = @($e.proutes).Count; dns = $e.dnsStatic }; c2 = $r2.code; s2 = $r2.said; wdis = $w.disabled; calls2 = @($script:sim.calls) }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN2 driver ran' $o } else {
    Check ($j.c1 -eq 0 -and $j.e.dhcp -and -not $j.e.act -and -not $j.e.per -and -not $j.e.routes -and -not $j.e.dns) 'RN static PC: DHCP on, the fixed address, the fixed router and the hand-set DNS are all gone, DONE' $j.s1
    Check ($j.c2 -eq 0 -and -not $j.wdis -and $j.s2 -match 'turn the adapter on' -and $j.s2 -match 'Reichman Mesh') 'RN a Wi-Fi adapter left switched OFF (Sitebox 2, Nov 8) is switched on and reconnected to its saved Wi-Fi' $j.s2
    Check (@($j.calls2)[0] -match '^enable') 'RN ...switching it on is the first change' ($j.calls2 -join "`n")
  }

  # =====================================================================================
  Write-Host 'Restore Network: failing half-way says FAILED - Run again, still switches WifiWatch back on; the next run finishes it'
  $o = Rn-Driver 'rn3' @'
$script:sim.ads = @((New-SimAdapter 'Ethernet' 12 $false))
$e = $script:sim.ads[0]; $e.coexist = 'enabled'; Sim-Ext '192.168.250.250' 'both'
'{"version":2,"temps":[{"ip":"192.168.250.250","ifIndex":12}],"pc":{"coexistence_before":"disabled"}}' | Set-Content (Join-Path $D 'FixNVR\state\temp-ips.json')
$script:sim.fail['removeaddr:PersistentStore'] = $true
$r1 = Run-Rn
$t1 = $script:sim.task; $j1 = Test-Path (Join-Path $D 'FixNVR\state\temp-ips.json'); $per1 = @($e.persistent).Count
$script:sim.fail = @{}
$r2 = Run-Rn
$moved = @(Get-ChildItem (Join-Path $D 'FixNVR\state') -Filter 'temp-ips.restored-*.json').Count
# stopped by an error in the middle of the run (not a single step): the finally still switches WifiWatch back on
Sim-Ext '192.168.250.251' 'both'; $e.coexist = 'enabled'; $script:sim.fail['coexist'] = $true; $script:sim.fail['reconnect'] = $true
$r3 = Run-Rn
Out-Result @{ c1 = $r1.code; s1 = $r1.said; t1 = $t1; j1 = $j1; per1 = $per1; c2 = $r2.code; s2 = $r2.said; per2 = @($e.persistent).Count; j2 = (Test-Path (Join-Path $D 'FixNVR\state\temp-ips.json')); moved = $moved; c3 = $r3.code; s3 = $r3.said; t3 = $script:sim.task }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN3 driver ran' $o } else {
    Check ($j.c1 -eq 6 -and $j.s1 -match 'FAILED - Run again' -and $j.s1 -match 'still saved') 'RN the saved copy cannot be removed: "FAILED - Run again" (exit 6) and says what is still wrong' $j.s1
    Check ($j.t1 -eq 'on') 'RN ...WifiWatch is switched back on even though the run failed (try/finally)'
    Check ($j.j1 -and $j.per1 -eq 1) 'RN ...Fix NVR''s record of that address is kept (nothing is forgotten while it is still on the PC)'
    Check ($j.c2 -eq 0 -and $j.per2 -eq 0 -and $j.s2 -match 'DONE - network is back to normal') 'RN run again: it finishes the job and says DONE' $j.s2
    Check (-not $j.j2 -and $j.moved -eq 1) 'RN ...then Fix NVR''s record is marked done (renamed, kept) so nothing tries to put it back again'
    Check ($j.c3 -eq 6 -and $j.t3 -eq 'on' -and $j.s3 -match 'FAILED - Run again') 'RN two steps fail in one run: FAILED - Run again, WifiWatch still back on' $j.s3
  }

  # =====================================================================================
  Write-Host 'Restore Network: the wrong adapter / another adapter''s record changes nothing'
  $o = Rn-Driver 'rn4' @'
$script:sim.ads = @((New-SimAdapter 'Ethernet' 12 $false), (New-SimAdapter 'Wi-Fi 2' 7 $true))
Sim-Ext '192.168.250.250' 'both'
$script:Adapter = 'Ethernet 9'
$r1 = Run-Rn; $calls1 = @($script:sim.calls); $per1 = @($script:sim.ads[0].persistent).Count
$script:Adapter = 'Wi-Fi 2'
'{"version":2,"before":{"ifIndex":12,"coexist":"disabled","dhcp":true},"coexistChanged":true,"temps":[{"ip":"192.168.250.250","ifIndex":12}]}' | Set-Content (Join-Path $D 'Toolkit\fixsite-runs\_state\fixsite-temp-ips.json')
$script:sim.calls.Clear(); $r2 = Run-Rn
Out-Result @{ c1 = $r1.code; s1 = $r1.said; calls1 = $calls1; per1 = $per1; c2 = $r2.code; s2 = $r2.said; calls2 = @($script:sim.calls); per2 = @($script:sim.ads[0].persistent).Count; j2 = (Test-Path (Join-Path $D 'Toolkit\fixsite-runs\_state\fixsite-temp-ips.json')) }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN4 driver ran' $o } else {
    Check ($j.c1 -eq 2 -and $j.s1 -match 'no network adapter called "Ethernet 9"' -and $j.s1 -match 'Nothing was changed' -and -not @($j.calls1).Count -and $j.per1 -eq 1) 'RN an adapter name this PC does not have: exit 2, "Nothing was changed", nothing touched' $j.s1
    Check ($j.c2 -eq 0 -and -not @($j.calls2 | ? { $_ -match 'Ethernet' -or $_ -match 'removeaddr' }).Count -and $j.per2 -eq 1) 'RN restoring Wi-Fi 2 leaves the Ethernet adapter (and its Toolkit address) alone' ($j.calls2 -join "`n")
    Check ($j.j2) 'RN ...and Fix this site''s record for the Ethernet adapter is kept (it is not this adapter''s)'
  }

  # =====================================================================================
  Write-Host 'Restore Network: Windows permission (UAC) only when something must change; no answer from the router is FAILED'
  $o = Rn-Driver 'rn5' @'
$script:sim.ads = @((New-SimAdapter 'Ethernet' 12 $false)); $script:sim.admin = $false
$r0 = Run-Rn; $el0 = $script:sim.elevated
Sim-Ext '192.168.250.250' 'both'
$script:sim.elevate = 'deny'; $r1 = Run-Rn; $per1 = @($script:sim.ads[0].persistent).Count
$script:sim.elevate = 'run'; $r2 = Run-Rn
$e = $script:sim.ads[0]; $e.routerAnswers = $false; $script:sim.admin = $true; $r3 = Run-Rn
$e.routerAnswers = $true; $e.cable = $false; $r4 = Run-Rn
Out-Result @{ c0 = $r0.code; s0 = $r0.said; el0 = $el0; c1 = $r1.code; s1 = $r1.said; per1 = $per1; c2 = $r2.code; s2 = $r2.said; per2 = @($e.persistent).Count; c3 = $r3.code; s3 = $r3.said; c4 = $r4.code; s4 = $r4.said }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN5 driver ran' $o } else {
    Check ($j.c0 -eq 0 -and $j.el0 -eq 0 -and $j.s0 -match 'DONE') 'RN a normal adapter, no admin rights: DONE with no Windows permission question' $j.s0
    Check ($j.c1 -eq 6 -and $j.s1 -match 'not given' -and $j.s1 -match 'FAILED - Run again' -and $j.per1 -eq 1) 'RN permission refused: "nothing was changed" + FAILED - Run again' $j.s1
    Check ($j.c2 -eq 0 -and $j.per2 -eq 0 -and $j.s2 -match 'click Yes' -and $j.s2 -match 'DONE') 'RN permission given: the admin copy does the work and its DONE is the result' $j.s2
    Check ($j.c3 -eq 6 -and $j.s3 -match 'no address from the router') 'RN cable in but the router gives no address: FAILED - Run again (never a false DONE)' $j.s3
    Check ($j.c4 -eq 8 -and $j.s4 -match 'NOT FIXED - run again or call' -and $j.s4 -match 'cable' -and $j.s4 -notmatch '(?m)^DONE') 'RN no cable: settings are normal but offline, so NOT FIXED - run again or call (exit 8), never DONE (2.2.11 round 2)' $j.s4
  }
  $rnSrc = [IO.File]::ReadAllText($rnFile)
  Check ($rnSrc -match "PolicyStore PersistentStore" -and $rnSrc -match "netsh interface ipv4 delete address") 'RN (Windows side) the saved copy is removed with Remove-NetIPAddress -PolicyStore PersistentStore and netsh delete'
  Check ($rnSrc -match '(?s)try \{\s*\$pz = Start-RnPause \$true.*Get-RnVerdict.*\} finally \{\s*\$e1 = Stop-RnPause') 'RN (Windows side) WifiWatch is paused inside try, kept paused through the final check (2.2.12), and switched back on in finally'
  Check ($rnSrc -notmatch '(?i)\b(openai|anthropic|claude|gpt|tab\.bot)\b') 'RN no Tab and no AI inside the tool'
  $cmdTxt = [IO.File]::ReadAllText((Join-Path $tk 'Restore Network.cmd'))
  Check ($cmdTxt -match 'RestoreNetwork\.ps1') 'RN "Restore Network.cmd" starts it on its own (standalone)'
  $shipped = [IO.File]::ReadAllText((Join-Path $repo 'tools\shipped-files.txt'))
  $inst = [IO.File]::ReadAllText((Join-Path $tk 'Install-Toolkit.ps1'))
  Check ($shipped -match 'Toolkit/RestoreNetwork\.ps1' -and $shipped -match 'Toolkit/Restore Network\.cmd' -and $inst -match "'RestoreNetwork\.ps1'" -and $inst -match "'Restore Network\.cmd'") 'RN shipped with the Toolkit (installer + shipped files list)'

  # =====================================================================================
  # =====================================================================================
  Write-Host 'Restore Network round 2, bug 1 (Sitebox 2, Nov 9): it reports the Wi-Fi it is REALLY on, read after the reconnect, never the first saved profile'
  $o = Rn-Driver 'rn6' @'
$w = New-SimAdapter 'Wi-Fi 2' 7 $true; $script:sim.ads = @($w)
# case A: adapter disabled; the first saved profile is "Lizard" but Windows rejoins "Reichman Mesh"
$w.disabled = $true; $w.assoc = $false
$rA = Run-Rn
$rcA = @(Get-ChildItem (Join-Path $D 'receipts') -Filter 'RestoreNetwork-*.txt' | Sort-Object LastWriteTime | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })[-1]
# case B: Wi-Fi dropped, settings normal, a standard user (no admin, no Windows question)
$script:sim.admin = $false; $w.assoc = $false; $recB0 = $w.reconnects
$rB = Run-Rn; $recB = $w.reconnects - $recB0; $elB = $script:sim.elevated
# case C: run twice - already on the Wi-Fi: no reconnect at all
$recC0 = $w.reconnects; $rC = Run-Rn; $recC = $w.reconnects - $recC0
Out-Result @{ cA = $rA.code; sA = $rA.said; rcA = $rcA; chA = $rA.changed; cB = $rB.code; sB = $rB.said; recB = $recB; elB = $elB; cC = $rC.code; sC = $rC.said; recC = $recC }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN6 driver ran' $o } else {
    Check ($j.cA -eq 0 -and $j.sA -match 'Wi-Fi connected to "Reichman Mesh"' -and $j.sA -notmatch 'Lizard') 'RN bug 1: disabled Wi-Fi comes back and the run names "Reichman Mesh" (what Windows joined), not "Lizard" (the first saved profile)' $j.sA
    Check ($j.rcA -match 'Reichman Mesh' -and $j.rcA -notmatch 'Lizard' -and $j.rcA -match 'Result: DONE') 'RN bug 1: the receipt says the same network ("Reichman Mesh") and DONE' $j.rcA
    Check ($j.sA -match 'DONE - network is back to normal and online \(Wi-Fi 2: Wi-Fi "Reichman Mesh"') 'RN bug 1: the DONE line carries the real network name' $j.sA
    Check ($j.cB -eq 0 -and $j.recB -ge 1 -and $j.elB -eq 0 -and $j.sB -match 'Wi-Fi connected to "Reichman Mesh"' -and $j.sB -match 'DONE') 'RN Wi-Fi drop, settings normal, standard user: it asks the Wi-Fi to join (no admin, no Windows question) and reports the real network' $j.sB
    Check ($j.cC -eq 0 -and $j.recC -eq 0 -and $j.sC -match 'DONE') 'RN run twice: already online on the Wi-Fi, the second run reconnects nothing and says DONE' $j.sC
  }
  # =====================================================================================
  Write-Host 'Restore Network round 2, bug 2 (Sitebox 2, Nov 9): DONE only when really online; still offline = NOT FIXED - run again or call, exit 8, same in the receipt'
  $o = Rn-Driver 'rn7' @'
$w = New-SimAdapter 'Wi-Fi 2' 7 $true; $script:sim.ads = @($w)
function Last-Rcpt { return @(Get-ChildItem (Join-Path $D 'receipts') -Filter 'RestoreNetwork-*.txt' | Sort-Object LastWriteTime, Name | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })[-1] }
# A: Wi-Fi dropped and it will NOT rejoin (out of range): retries, one more join request, then NOT FIXED
$w.assoc = $false; $w.joins = $false; $w.onlineCalls = 0; $w.reconnects = 0
$rA = Run-Rn; $rcA = Last-Rcpt; $oA = $w.onlineCalls; $reA = $w.reconnects
# B: on the Wi-Fi, the router answers, no internet
$w.assoc = $true; $w.joins = $true; $w.internet = $false; $rB = Run-Rn; $rcB = Last-Rcpt
# C: the router does not answer a ping
$w.internet = $true; $w.gwAnswers = $false; $rC = Run-Rn
# D: slow: online only on the 4th check -> DONE after retrying
$w.gwAnswers = $true; $w.onlineCalls = 0; $w.onlineAfter = 3; $rD = Run-Rn; $oD = $w.onlineCalls
# E: failing half-way - the check itself breaks (and the fix runs as admin with WifiWatch paused): NOT FIXED, WifiWatch back on
$w.onlineAfter = 0; $w.dhcp = $false; $script:sim.fail['online'] = $true; $script:sim.task = 'on'
$rE = Run-Rn; $rcE = Last-Rcpt; $taskE = $script:sim.task; $script:sim.fail.Remove('online')
# F: run again after NOT FIXED, the world fixed: DONE (Moshe: "run again" is fine when the tool says so honestly)
$rF = Run-Rn
Out-Result @{ cA = $rA.code; sA = $rA.said; rcA = $rcA; oA = $oA; reA = $reA; cB = $rB.code; sB = $rB.said; rcB = $rcB; cC = $rC.code; sC = $rC.said; cD = $rD.code; sD = $rD.said; oD = $oD; cE = $rE.code; sE = $rE.said; rcE = $rcE; taskE = $taskE; cF = $rF.code; sF = $rF.said }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN7 driver ran' $o } else {
    Check ($j.cA -eq 8 -and $j.sA -match '(?m)^NOT FIXED - run again or call' -and $j.sA -notmatch '(?m)^DONE' -and $j.sA -match 'not connected to any network') 'RN bug 2: Wi-Fi dropped and it does not rejoin: NOT FIXED - run again or call, exit 8, never DONE' $j.sA
    Check ($j.rcA -match 'Result: NOT FIXED - run again or call' -and $j.rcA -notmatch 'Result: DONE') 'RN bug 2: the receipt says NOT FIXED too' $j.rcA
    Check ($j.oA -ge 5 -and $j.reA -ge 2) 'RN bug 2: it keeps checking (about 40 s) and asks the Wi-Fi to join once more before giving up' ('checks ' + $j.oA + ', join requests ' + $j.reA)
    Check ($j.cB -eq 8 -and $j.sB -match 'internet does not' -and $j.rcB -match 'NOT FIXED') 'RN on the Wi-Fi, router answers but no internet: NOT FIXED with the plain reason' $j.sB
    Check ($j.cC -eq 0 -and $j.sC -match 'router 192\.168\.4\.1 does not answer ping' -and $j.sC -match '(?m)^DONE') 'RN the router does not answer a ping but the web answers through this adapter: DONE, the ping only noted (2.2.12, Codex P1-6; was NOT FIXED in 2.2.11)' $j.sC
    Check ($j.cD -eq 0 -and $j.oD -eq 4 -and $j.sD -match 'DONE - network is back to normal and online') 'RN slow network: it retries and says DONE once the 4th check is online' ('checks ' + $j.oD + "`n" + $j.sD)
    Check ($j.cE -eq 8 -and $j.sE -match 'NOT FIXED' -and $j.taskE -eq 'on' -and $j.rcE -match 'NOT FIXED' -and $j.sE -match 'DHCP on') 'RN failing half-way (the online check breaks): DHCP still fixed, NOT FIXED, receipt written, WifiWatch back on' $j.sE
    Check ($j.cF -eq 0 -and $j.sF -match 'DONE') 'RN run again after NOT FIXED: DONE once the network is really back' $j.sF
  }
  # =====================================================================================
  Write-Host 'Restore Network round 2: the wrong adapter / another adapter is never reconnected or checked'
  $o = Rn-Driver 'rn8' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $w = New-SimAdapter 'Wi-Fi 2' 7 $true; $script:sim.ads = @($e, $w)
$w.assoc = $false; $script:Adapter = 'Wi-Fi 9'; $r1 = Run-Rn
$rec1 = $w.reconnects + $e.reconnects; $on1 = $w.onlineCalls + $e.onlineCalls
$script:Adapter = 'Ethernet'; $r2 = Run-Rn
Out-Result @{ c1 = $r1.code; s1 = $r1.said; rec1 = $rec1; on1 = $on1; c2 = $r2.code; s2 = $r2.said; wRec = $w.reconnects; wOn = $w.onlineCalls; eOn = $e.onlineCalls }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RN8 driver ran' $o } else {
    Check ($j.c1 -eq 2 -and $j.rec1 -eq 0 -and $j.on1 -eq 0) 'RN a wrong adapter name: exit 2, nothing reconnected, nothing checked' $j.s1
    Check ($j.c2 -eq 0 -and $j.wRec -eq 0 -and $j.wOn -eq 0 -and $j.eOn -ge 1 -and $j.s2 -notmatch 'Wi-Fi') 'RN Ethernet chosen while the Wi-Fi is down: only Ethernet is checked, the Wi-Fi is left alone' $j.s2
  }
  # =====================================================================================
  Write-Host 'Restore Network round 2: reading netsh (the real network name, the saved profile in range) - also on Windows PowerShell 5.1'
  $parse = @'
$ifs = "There are 2 interfaces on the system: `r`n`r`n    Name                   : Wi-Fi`r`n    Description            : Realtek`r`n    State                  : connected`r`n    SSID                   : Office 5G`r`n    BSSID                  : aa:bb:cc:dd:ee:ff`r`n    Profile                : Office 5G`r`n`r`n    Name                   : Wi-Fi 2`r`n    Description            : Intel(R) Dual Band Wireless-AC 7260 #2`r`n    State                  : connected`r`n    SSID                   : Reichman Mesh`r`n    BSSID                  : 11:22:33:44:55:66`r`n    Profile                : Reichman Mesh`r`n"
$dis = "There is 1 interface on the system: `r`n`r`n    Name                   : Wi-Fi 2`r`n    Description            : Intel`r`n    State                  : disconnected`r`n    Radio status           : Hardware On`r`n"
$prof = "Profiles on interface Wi-Fi 2:`r`n`r`nUser profiles`r`n-------------`r`n    All User Profile     : Lizard`r`n    All User Profile     : Reichman Mesh`r`n"
$one = "User profiles`r`n-------------`r`n    All User Profile     : Reichman Mesh`r`n"
$nets = "Interface name : Wi-Fi 2 `r`nThere are 2 networks currently visible. `r`n`r`nSSID 1 : Reichman Mesh`r`n    Network type            : Infrastructure`r`n`r`nSSID 2 : NETGEAR-Guest`r`n"
$a = ConvertFrom-RnWlanText $ifs 'Wi-Fi 2'; $b = ConvertFrom-RnWlanText $dis 'Wi-Fi 2'; $c = ConvertFrom-RnWlanText $ifs 'Wi-Fi 7'
$p1 = Select-RnWifiProfile $prof $nets; $p2 = Select-RnWifiProfile $one $nets; $p3 = Select-RnWifiProfile $prof ''
$ok1 = Test-RnOnlineOk ([pscustomobject]@{ link = $true; ip = '169.254.3.4'; gw = '192.168.4.1'; gwPing = $true; dns = $true; http = $true })
$ok2 = Test-RnOnlineOk ([pscustomobject]@{ link = $true; ip = '192.168.4.31'; gw = '192.168.4.1'; gwPing = $true; dns = $false; http = $true })
'JSON=' + (@{ v = $PSVersionTable.PSVersion.Major; a = $a; b = $b; c = $c; p1 = $p1; p2 = $p2; p2t = $p2.GetType().Name; p3 = $p3; ok1 = $ok1; ok2 = $ok2 } | ConvertTo-Json -Compress -Depth 4)
'@
  $fnText = Get-FnText $rnFile @('ConvertFrom-RnWlanText', 'Select-RnWifiProfile', 'Test-RnOnlineOk')
  $engines = @(@{ n = 'this PowerShell'; exe = $exe })
  $ps51 = $(if ($env:windir) { Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' })
  $ps51Deferred = $false
  if ($ps51 -and (Test-Path -LiteralPath $ps51)) { if ($exe -ne $ps51) { $engines += @{ n = 'Windows PowerShell 5.1'; exe = $ps51 } } } else { $ps51Deferred = $true }
  foreach ($en in $engines) {
    $f = Join-Path $tmp ('rnparse-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1'); [IO.File]::WriteAllText($f, ($fnText + "`n" + $parse), (New-Object Text.UTF8Encoding($true)))
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $po = & $en.exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
    $j = Get-Json $po; $tag = 'RN netsh (' + $en.n + $(if ($j) { ' ' + $j.v } else { '' }) + '): '
    if (-not $j) { Check $false ($tag + 'parser ran') $po; continue }
    Check ($j.a.connected -and $j.a.ssid -eq 'Reichman Mesh' -and $j.a.profile -eq 'Reichman Mesh') ($tag + 'two Wi-Fi interfaces: the network of "Wi-Fi 2" is read from its own block (not the BSSID line, not the other card)') $po
    Check ((-not $j.b.connected) -and $j.b.ssid -eq '' -and (-not $j.c.connected)) ($tag + 'a disconnected Wi-Fi (no SSID line) and an unknown interface read as NOT connected') $po
    Check ($j.p1 -eq 'Reichman Mesh' -and $j.p2 -eq 'Reichman Mesh' -and $j.p2t -eq 'String' -and $j.p3 -eq '') ($tag + 'the saved profile asked for is the one IN RANGE (not the first saved, "Lizard"); one saved profile stays one name; none in range = none') $po
    Check ((-not $j.ok1) -and $j.ok2) ($tag + 'a 169.254 address is never "online"; router ping + the web without DNS is online') $po
  }
  $coreSrc = [IO.File]::ReadAllText((Join-Path $tk 'ToolkitCore.ps1'))
  Check ($coreSrc -match "8 \{ return \('NOT FIXED - run again or call\. '") 'RN the Toolkit window ends a NOT FIXED run (exit 8) with "NOT FIXED - run again or call", not "stopped with a problem"; 7 stays Fix this site''s own code'
  if ($ps51Deferred) { $script:deferred++; Write-Host 'DEFERRED PS51 RN netsh parser on Windows PowerShell 5.1 (this machine has no powershell.exe; runs on the Windows suite)' }
  Write-Host 'WifiWatch: the off/on cycle always switches the adapter back on (try/finally + marker for a run stopped half-way)'
  $wwFile = Join-Path $repo 'wifiwatch\WifiWatch.ps1'
  $wd = Join-Path $tmp 'ww'; New-Item -ItemType Directory -Force -Path $wd | Out-Null
  $o = Invoke-Driver 'ww1' ('$ErrorActionPreference = ''Continue''; . ' + (Q $wwFile) + ' -Dir ' + (Q $wd) + "`n" + @'
$script:ww = @{ up = $true; failEnable = 0; failDisable = $false; calls = (New-Object System.Collections.ArrayList) }
$script:WwOps = { param($op, $a) if ($op -ne 'sleep') { [void]$script:ww.calls.Add($op) }
  switch ($op) {
    'disable' { if ($script:ww.failDisable) { throw 'simulated disable error' }; $script:ww.up = $false; return $true }
    'enable' { if ($script:ww.failEnable -gt 0) { $script:ww.failEnable--; throw 'simulated enable error' }; $script:ww.up = $true; return $true }
    'isup' { return $script:ww.up }
    default { return $true } } }
Invoke-WwAdapterCycle 'Wi-Fi 2' 'Reichman Mesh'
$a1 = $script:ww.up; $m1 = Test-Path $marker
$script:ww.failEnable = 5; Invoke-WwAdapterCycle 'Wi-Fi 2' 'Reichman Mesh'
$a2 = $script:ww.up; $m2 = Test-Path $marker
$script:ww.failEnable = 0; Repair-WwAdapter
$a3 = $script:ww.up; $m3 = Test-Path $marker
$script:ww.calls.Clear(); Repair-WwAdapter; $c4 = @($script:ww.calls).Count
$script:ww.failDisable = $true; Invoke-WwAdapterCycle 'Wi-Fi 2' 'Reichman Mesh'; $a5 = $script:ww.up; $m5 = Test-Path $marker
'JSON=' + (@{ a1 = $a1; m1 = $m1; a2 = $a2; m2 = $m2; a3 = $a3; m3 = $m3; c4 = $c4; a5 = $a5; m5 = $m5; log = [IO.File]::ReadAllText($log) } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'WW driver ran' $o } else {
    Check ($j.a1 -and -not $j.m1) 'WW a normal off/on cycle ends with the adapter ON and no marker left'
    Check ((-not $j.a2) -and $j.m2) 'WW switching it back on fails (half-way): the marker stays, so the next run knows' $j.log
    Check ($j.a3 -and -not $j.m3) 'WW the next run switches the adapter back on FIRST and removes the marker' $j.log
    Check ($j.c4 -eq 0) 'WW running the repair twice does nothing the second time'
    Check ($j.a5 -and -not $j.m5) 'WW an error while switching it off still ends with the adapter on (finally)'
  }
  $wwSrc = [IO.File]::ReadAllText($wwFile)
  $iRep = $wwSrc.IndexOf("`r`nRepair-WwAdapter`r`n"); $iPz = $wwSrc.IndexOf("`r`nif (Test-WwPaused) {"); $iF = $wwSrc.IndexOf("`r`n`$fails = 0")
  Check ($wwSrc -match '(?m)^Repair-WwAdapter\s*$' -and $iRep -gt 0 -and $iPz -gt $iRep -and $iF -gt $iPz) 'WW every run starts with the repair, before it looks at the network (2.2.12: then the Restore Network pause check, then the network)'

  # =====================================================================================
  Write-Host 'F16 / Codex R14: classic Fix NVR with no usable config.json stops with a plain message (missing, empty, half-written, another tool''s file, twice)'
  $fnv = Join-Path $repo 'FixNVR\FixNVR.ps1'
  $f16 = Join-Path $tmp 'f16'; New-Item -ItemType Directory -Force -Path $f16 | Out-Null
  Copy-Item $fnv (Join-Path $f16 'FixNVR.ps1')
  $mock16 = Join-Path $f16 'mock.json'; '{"url":"http://127.0.0.1:9","pc":{"ifIndex":1,"alias":"Ethernet","desc":"t","ip":"192.168.1.105","prefix":24,"gw":"192.168.1.1","dhcp":true,"link":"1 Gbps","wifi":false},"sadp":[],"arp":[],"onvif":[]}' | Set-Content $mock16
  $cases = [ordered]@{ 'NO' = (Join-Path $f16 'missing.json'); 'an EMPTY (0 bytes)' = (Join-Path $f16 'zero.json'); 'a HALF-WRITTEN' = (Join-Path $f16 'half.json'); 'ANOTHER TOOL''S (the Toolkit''s)' = (Join-Path $f16 'other.json') }
  [IO.File]::WriteAllText($cases['an EMPTY (0 bytes)'], ''); '{"nvr_hosts":[20,19' | Set-Content $cases['a HALF-WRITTEN']; '{"hikvisionForm":"https://x","bitwardenUrl":"https://y"}' | Set-Content $cases['ANOTHER TOOL''S (the Toolkit''s)']
  foreach ($k in $cases.Keys) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o16 = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $f16 'FixNVR.ps1') -Mode Check -ConfigPath $cases[$k] -MockFile $mock16 -NoLogin -SniffSeconds 0 2>&1 | Out-String; $c16 = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $plans = @(Get-ChildItem -LiteralPath (Join-Path $f16 'runs') -Recurse -Filter 'before.json' -ErrorAction SilentlyContinue).Count
    Check ($c16 -eq 2 -and $o16 -match 'config\.json' -and $o16 -match 'Nothing was checked or changed' -and $o16 -notmatch '(?i)Get-Content|Exception|At line' -and -not $plans) ('F16 ' + $k + ' config.json: one plain message, no red error, exit 2, nothing looked at') $o16
  }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $o2 = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $f16 'FixNVR.ps1') -Mode Check -ConfigPath $cases['NO'] -MockFile $mock16 -NoLogin -SniffSeconds 0 2>&1 | Out-String; $c2 = $LASTEXITCODE
  $ErrorActionPreference = $prev
  Check ($c2 -eq 2 -and $o2 -match 'Nothing was checked or changed') 'F16 running it twice: the same plain message again'
  $logs = @(Get-ChildItem -LiteralPath (Join-Path $f16 'runs') -Recurse -Filter 'log.txt' -ErrorAction SilentlyContinue | Where-Object { [IO.File]::ReadAllText($_.FullName) -match 'SAY Fix NVR cannot start' })
  Check ($logs.Count -ge 1) 'F16 the message is in the run log too, so the Toolkit window shows it'
  $fsrc = [IO.File]::ReadAllText($fnv)
  Check ($fsrc -match "if \(\`$cfgWhy -and \`$Mode -eq 'Cleanup'\)") 'F16 -Mode Cleanup still runs without config.json (a missing settings file never keeps the network from being put back)'

  # =====================================================================================
  Write-Host 'R17: Run-AllTests never counts a suite with deferred checks as a pass'
  $rat = Join-Path $repo 'tools\Run-AllTests.ps1'
  $o = Invoke-Driver 'r17' ((Get-FnText $rat @('Get-SuiteCounts', 'Get-SuiteResult')) + "`n" + @'
$a = Get-SuiteCounts @('PASS x', 'DEFERRED F19 y', 'Test-Fix227: 41 passed, 0 failed, 7 deferred (F15, F16)')
$b = Get-SuiteCounts @('PASS x', '127 passed, 0 failed')
$c = Get-SuiteCounts @('PASS x', 'DEFERRED F20 a', 'DEFERRED F20 b', '3 passed, 0 failed')
$d = Get-SuiteCounts @('PASS R17 the suite''s own "41 passed, 0 failed, 7 deferred" is read', 'Test-Fix2211: 55 passed, 0 failed')
'JSON=' + (@{ a = $a; ra = (Get-SuiteResult 0 $a); b = $b; rb = (Get-SuiteResult 0 $b); c = $c; rc = (Get-SuiteResult 0 $c); rf = (Get-SuiteResult 1 $a); rf2 = (Get-SuiteResult 2 $b); d = $d; rd = (Get-SuiteResult 0 $d) } | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'R17 driver ran' $o } else {
    Check ($j.a.passed -eq 41 -and $j.a.failed -eq 0 -and $j.a.deferred -eq 7) 'R17 the suite''s own "41 passed, 0 failed, 7 deferred" is read'
    Check ($j.ra -eq 'DEFERRED') 'R17 a suite that exits 0 WITH deferred checks is DEFERRED, not PASS (Codex R17)'
    Check ($j.rb -eq 'PASS' -and $j.b.deferred -eq 0) 'R17 a suite with no deferred check that exits 0 is PASS'
    Check ($j.c.deferred -eq 2 -and $j.rc -eq 'DEFERRED') 'R17 DEFERRED lines count even when the summary line does not mention them'
    Check ($j.rf -eq 'FAIL' -and $j.rf2 -eq 'FAIL') 'R17 a failing suite stays FAIL (with or without deferred)'
    Check ($j.d.passed -eq 55 -and $j.d.deferred -eq 0 -and $j.rd -eq 'PASS') 'R17 a check NAME that quotes "7 deferred" is not read as the suite''s summary (the last real summary line counts)'
  }
  $ratSrc = [IO.File]::ReadAllText($rat)
  Check ($ratSrc -match 'exit \(\$bad \+ \$deferredSuites\)' -and $ratSrc -match "ALL ' \+ \`$scope \+ ' PASSED'" -and $ratSrc -match 'elseif \(\$deferredSuites\)') 'R17 "ALL SUITES PASSED" and exit 0 only with no failed AND no deferred suite'
  Check ($ratSrc -match 'Test-Fix2211\.ps1') 'R17 this suite is in Run-AllTests'
  Write-Host 'job receipt (#4) for Fix this site: the wrong site / stopped early still leaves a receipt, a second run its own'
  $rd = Join-Path $tmp 'rcpt'; $env:WIREIT_RECEIPT_DIR = $rd
  foreach ($i in 1, 2) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $null = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tk 'FixSite.ps1') -Mode Fix -Site 'Qq Nosuch Test 2211' -MockUrl 'http://127.0.0.1:9' -Answers (Join-Path $tmp 'none.txt') -RunsRoot (Join-Path $tmp 'rcruns') -SecretsDir (Join-Path $tmp 'rcsec') -SitesDir (Join-Path $tmp 'rcsites') 2>&1 | Out-String
    $ErrorActionPreference = $prev
    Start-Sleep -Milliseconds 1100
  }
  $env:WIREIT_RECEIPT_DIR = $null
  $rcs = @(Get-ChildItem $rd -Filter 'FixSite-*.txt' -ErrorAction SilentlyContinue)
  $rt = $(if ($rcs.Count) { [IO.File]::ReadAllText($rcs[0].FullName) } else { '' })
  Check ($rcs.Count -eq 2) ('receipt: two runs -> two receipts, the first one is not overwritten (' + $rcs.Count + ')')
  Check ($rt -match 'Site: Qq Nosuch Test 2211' -and $rt -match 'Result: (stopped|STOPPED HALF-WAY|DONE)' -and $rt -match 'Changed on the cameras / NVR:\s+- nothing') 'receipt: a run on a site this PC does not know (stopped half-way here: no network) says so and that nothing was changed' $rt
  $rtl = @(([string]$rt) -split "`r?`n")
  Check ($rtl[0] -match '^WireIt Toolkit [0-9.]+ - Fix this site receipt' -and $rtl[1] -match '^Site: ' -and $rtl[2] -match '^PC: ' -and $rtl[3] -match '^Result: ') 'receipt: one fact per line (title, site, PC, result)' ($rtl[0..3] -join ' | ')
  Write-Host 'version + the Toolkit button'
  $v11 = @(([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'ToolkitCore.ps1')), "TkBuiltVersion = '([0-9.]+)'")).Groups[1].Value, ([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'FixSiteCore.ps1')), "FsVersion = '([0-9.]+)'")).Groups[1].Value, ([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'FixSiteBw.ps1')), "FsVersion = '([0-9.]+)'")).Groups[1].Value, [string]([IO.File]::ReadAllText((Join-Path $repo 'version.json')) | ConvertFrom-Json).version)
  Check ((($v11 | Select-Object -Unique) -join ',') -eq '2.2.17') ('version 2.2.17 (2.2.17: bumped from 2.2.16) in ToolkitCore, FixSiteCore, FixSiteBw and version.json (' + ($v11 -join ',') + ')')
  $ui = [IO.File]::ReadAllText((Join-Path $tk 'WireItToolkit.ps1'))
  Check ($ui -match "New-Btn 'Restore network' \{ Do-RestoreNet \}" -and $ui -match "Start-Hidden 'Restore Network' \`$rn") 'the Toolkit window has a "Restore network" button that runs RestoreNetwork.ps1'
  # 2.2.11 Office GUI click (Nov 9): on Windows PowerShell 5.1 ConvertFrom-Json hands back a JSON list as ONE item, so with
  # Ethernet + Wi-Fi the button skipped its pick list and ran Restore Network on an adapter named "Ethernet Wi-Fi" (FAILED, exit 2)
  $pl = [regex]::Match($ui, '\$ads = @\(\$m\.Groups\[1\]\.Value\.Trim\(\) \| ConvertFrom-Json[^)]*\)').Value
  foreach ($case in @(@('[{"name":"Ethernet","desc":"a","needs":false},{"name":"Wi-Fi","desc":"b","needs":false}]', 2), @('[{"name":"Ethernet","desc":"a","needs":false}]', 1))) {
    $t = 'JSON=' + $case[0]; $m = [regex]::Match($t, '(?m)^JSON=(.+)$'); $ads = @(); if ($pl) { Invoke-Expression $pl }
    Check ($ads.Count -eq $case[1] -and [string]$ads[0].name -eq 'Ethernet' -and -not ([string]$ads[0].name).Contains(' ')) ('the Restore network button reads ' + $case[1] + ' adapter(s) as ' + $case[1] + ' choice(s), each with its own name (not "Ethernet Wi-Fi")') ('got ' + $ads.Count + ': ' + (@($ads | ForEach-Object { [string]$_.name }) -join ' | '))
  }
} finally {
  try { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue } catch {}
}
Write-Host ''
Write-Host ('Test-Fix2211: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
