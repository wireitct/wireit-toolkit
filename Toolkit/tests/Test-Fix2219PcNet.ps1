<# Test-Fix2219PcNet.ps1 - WireIt Toolkit 2.2.19, the laptop's own network recovery and safety records (Codex review of 2.2.18,
   head a7ceac8): F05 (adapter identity before every recovery change), F08 (an unreadable adapter state keeps every piece of
   recovery evidence), F09 (a damaged-but-readable recovery record is quarantined under the durable block), F27 (an unreadable or
   unsavable wrong-password count holds further logins; every try is written down before it is sent), F18 (Restore Network:
   an unreadable relevant setting is NOT CHECKED, never DONE), F21 (WifiWatch keeps an unreadable adapter-off marker and the block),
   plus the decision "a restart alone never clears the recovery block: a positive check of every adapter does".
   The real FixSiteCore.ps1 / FixSiteDevices.ps1, RestoreNetwork.ps1 and wifiwatch/WifiWatch.ps1 are loaded in their own PowerShell
   process per group; only Windows' network commands and devices are stand-ins (as in Codex's reproductions). Codex's own
   reproduction scripts site.ps1 / restore-network.ps1 / known-open.ps1 (F21 part) are rebuilt here as checks marked "Codex repro".
   Checks marked "control" pass on old and new code. FIX2219PCNET_REPO = another checkout (e.g. 2.2.18 a7ceac8) to prove these
   checks fail there. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2219PCNET_REPO) { $repo = $env:FIX2219PCNET_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2219pcnet-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, $more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = $(if ($more -is [string]) { $more } else { ConvertTo-Json -Compress -Depth 6 -InputObject $more }); Write-Host ('     ' + ($m -replace "`n", "`n     ")) } }
}
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function P($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { return $o.$k }; return $null }
$siteDrv = @'
function P($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { return $o.$k }; return $null }

$ErrorActionPreference = 'Continue'
$script:Log = New-Object System.Collections.ArrayList
function Fs-LogLine([string]$s) { [void]$script:Log.Add($s) }
$R = [ordered]@{}
function Run([string]$name, [scriptblock]$sb) { try { $R[$name] = (& $sb) } catch { $R[$name] = [ordered]@{ error = ($_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber) } } }
function JF([string]$n) { $f = Join-Path (Join-Path $D $n) 'fixsite-temp-ips.json'; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null; return $f }
function Files([string]$f) { return @(Get-ChildItem -LiteralPath (Split-Path -Parent $f) -File | ForEach-Object { $_.Name }) }
function Reset { $script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $script:FsNetBlocked = $null; $script:Log.Clear(); $script:FsRestoreChecks = 1; $script:FsMockUrl = '' }
# a stand-in adapter: name/guid answered by 'ident' (swapAt = from that ident call on, another adapter answers at the number)
function New-Sim([hashtable]$o = @{}) {
  $script:sim = @{ name = 'Original Ethernet'; guid = '{0a0a0a0a-1111-2222-3333-444444444444}'; identFail = $false; identN = 0; swapAt = -1; dhcp = $true; coexist = 'disabled'
    addrs = New-Object System.Collections.ArrayList; gw = @(); writes = New-Object System.Collections.ArrayList; stateN = 0; stateNull = $false; unreadFrom = -1; addResult = 'Preferred'; removeWorks = $true }
  foreach ($k in @($o.Keys)) { $script:sim[$k] = $o[$k] }
  $script:FsNetOps = @{
    ident = { param($a) $script:sim.identN++; if ($script:sim.identFail) { throw 'Get-NetAdapter: the adapter could not be read' }; $nm = $script:sim.name; $g = $script:sim.guid; if ($script:sim.swapAt -ge 1 -and $script:sim.identN -ge $script:sim.swapAt) { $nm = 'Replacement Wi-Fi'; $g = '{0b0b0b0b-5555-6666-7777-888888888888}' }; [pscustomobject]@{ name = $nm; guid = $g } }
    state = { param($a) $script:sim.stateN++; if ($script:sim.stateNull) { return $null }; $u = @(); if ($script:sim.unreadFrom -ge 1 -and $script:sim.stateN -ge $script:sim.unreadFrom) { $u = @('the addresses') }; [pscustomobject]@{ dhcp = $script:sim.dhcp; coexist = $script:sim.coexist; addrs = @($script:sim.addrs); gw = @($script:sim.gw); unread = $u } }
    remove = { param($a) [void]$script:sim.writes.Add('remove ' + $a.ip); if ($script:sim.removeWorks) { foreach ($x in @($script:sim.addrs | Where-Object { $_.ip -eq $a.ip })) { $script:sim.addrs.Remove($x) } }; return $true }
    dhcp = { param($a) [void]$script:sim.writes.Add('dhcp ' + $a.on); $script:sim.dhcp = [bool]$a.on; return $true }
    coexist = { param($a) [void]$script:sim.writes.Add('coexist ' + $a.on); $script:sim.coexist = $(if ($a.on) { 'enabled' } else { 'disabled' }); return $true }
    addtemp = { param($a) [void]$script:sim.writes.Add('addtemp ' + $a.ip); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = 24; origin = 'Manual'; skip = $true }); return $script:sim.addResult }
    addstatic = { param($a) [void]$script:sim.writes.Add('addstatic ' + $a.ip); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = 24; origin = 'Manual'; skip = $false }); return $true }
    addroute = { param($a) [void]$script:sim.writes.Add('addroute ' + $a.gw); $script:sim.gw = @($script:sim.gw) + $a.gw; return $true }
    renew = { param($a) return $true }; wait = { param($a) return $true }; free = { param($a) return $true }
  }
}
function Before([string]$name = 'Original Ethernet', [string]$guid = '{0a0a0a0a-1111-2222-3333-444444444444}', [bool]$dhcp = $true) {
  $o = [ordered]@{ ifIndex = 5; name = $name; dhcp = $dhcp; coexist = 'disabled'; addrs = @([pscustomobject]@{ ip = '10.0.0.105'; prefix = 24; skip = $false }); gw = @() }
  if ($guid) { $o.guid = $guid }
  return [pscustomobject]$o
}
function Res($rr, [string]$f) { return [ordered]@{ ok = [bool]$rr.ok; problems = (@($rr.problems) -join ' | '); writes = @($script:sim.writes); journal = (Test-Path -LiteralPath $f); temps = @($script:FsTemps).Count; before = ($null -ne $script:FsPcBefore); log = (@($script:Log) -join ' | ') } }

# ---------------- F05 ----------------
Run 'f05_changed' { Reset; New-Sim @{ swapAt = 1; dhcp = $false }; $script:FsPcBefore = Before; $f = JF 'f05a'; Save-FsNetState $f; Res (Restore-FsPcNet $f) $f }
Run 'f05_codex' { Reset
  $script:dhcpNow = $false; $script:adapterWrites = @()
  $script:FsPcBefore = [pscustomobject]@{ ifIndex = 5; name = 'Original Ethernet'; dhcp = $true; coexist = 'disabled'; addrs = @([pscustomobject]@{ ip = '10.0.0.105' }); gw = @() }
  $script:FsNetOps = @{ state = { param($a) return [pscustomobject]@{ name = 'Replacement Wi-Fi'; dhcp = $script:dhcpNow; coexist = 'disabled'; addrs = @([pscustomobject]@{ ip = '192.168.55.105'; skip = $false }); gw = @() } }; dhcp = { param($a) $script:adapterWrites += ('enable DHCP on ifIndex ' + $a.ifIndex); $script:dhcpNow = $true; return $true } }
  $f = JF 'f05b'; Save-FsNetState $f; $rr = Restore-FsPcNet $f
  [ordered]@{ ok = [bool]$rr.ok; writes = @($script:adapterWrites); journal = (Test-Path -LiteralPath $f) } }
Run 'f05_identfail' { Reset; New-Sim @{ identFail = $true; dhcp = $false }; $script:FsPcBefore = Before; [void]$script:FsTemps.Add([pscustomobject]@{ p3 = '192.168.0'; ip = '192.168.0.253'; ifIndex = 5 }); $f = JF 'f05c'; Save-FsNetState $f; Res (Restore-FsPcNet $f) $f }
Run 'f05_same' { Reset; New-Sim @{ dhcp = $false }; [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '10.0.0.105'; prefix = 24; skip = $false }); $script:FsPcBefore = Before; $f = JF 'f05d'; Save-FsNetState $f; Res (Restore-FsPcNet $f) $f }
Run 'f05_noguid_same' { Reset; New-Sim @{ dhcp = $false }; [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '10.0.0.105'; prefix = 24; skip = $false }); $script:FsPcBefore = Before -guid ''; $f = JF 'f05e'; Save-FsNetState $f; Res (Restore-FsPcNet $f) $f }
Run 'f05_noguid_other' { Reset; New-Sim @{ dhcp = $false; name = 'Ethernet 2' }; $script:FsPcBefore = Before -guid ''; $f = JF 'f05f'; Save-FsNetState $f; Res (Restore-FsPcNet $f) $f }
Run 'f05_swap_midway' { Reset; New-Sim @{ dhcp = $false; swapAt = 3 }; [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.0.253'; prefix = 24; skip = $true })
  $script:FsPcBefore = Before; [void]$script:FsTemps.Add([pscustomobject]@{ p3 = '192.168.0'; ip = '192.168.0.253'; ifIndex = 5 }); $f = JF 'f05g'; Save-FsNetState $f; Res (Restore-FsPcNet $f) $f }
$pcA = [pscustomobject]@{ ip = '10.0.0.105'; prefix = 24; mask = '255.255.255.0'; gw = '10.0.0.1'; ifIndex = 5; dhcp = $true; name = 'Original Ethernet' }
Run 'f05_add_identfail' { Reset; New-Sim @{ identFail = $true }; $f = JF 'f05h'; $t = Add-FsTempIp '192.168.0' $pcA $f; [ordered]@{ added = [string]$t; writes = @($script:sim.writes) } }
Run 'f05_add_saves_guid' { Reset; New-Sim; $f = JF 'f05i'; $t = Add-FsTempIp '192.168.0' $pcA $f; $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; [ordered]@{ added = [string]$t; guid = [string](P $j.before 'guid'); name = [string]$j.before.name } }
Run 'f05_add_coexist_unknown' { Reset; New-Sim @{ coexist = 'unknown' }; $f = JF 'f05k'; $t = Add-FsTempIp '192.168.0' $pcA $f; [ordered]@{ added = [string]$t; writes = @($script:sim.writes) } }
$pcS = [pscustomobject]@{ ip = '10.0.0.105'; prefix = 24; mask = '255.255.255.0'; gw = '10.0.0.1'; ifIndex = 5; dhcp = $false; name = 'Original Ethernet' }
Run 'f05_dup_swap' { Reset; New-Sim @{ dhcp = $false; swapAt = 3; addResult = 'Duplicate' }; $f = JF 'f05j'; $t = Add-FsTempIp '192.168.0' $pcS $f; $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; [ordered]@{ added = [string]$t; writes = @($script:sim.writes); journalTemps = @($j.temps).Count } }

# ---------------- F08 ----------------
Run 'f08_codex_null' { Reset; $script:FsTemps.Clear(); [void]$script:FsTemps.Add([pscustomobject]@{ ip = '192.168.0.253'; ifIndex = 5; p3 = '192.168.0' })
  $script:FsPcBefore = [pscustomobject]@{ ifIndex = 5; name = 'Ethernet'; dhcp = $true; addrs = @(); gw = @() }
  $script:FsNetOps = @{ remove = { param($a) return $false }; state = { param($a) return $null }; ident = { param($a) [pscustomobject]@{ name = 'Ethernet'; guid = '' } } }
  $f = JF 'f08a'; Save-FsNetState $f; $rr = Restore-FsPcNet $f
  [ordered]@{ ok = [bool]$rr.ok; journal = (Test-Path -LiteralPath $f); temps = @($script:FsTemps).Count; before = ($null -ne $script:FsPcBefore) } }
# the production state reader, with stand-ins only for the Windows commands (Codex's raw reproduction, adapter identity readable)
function Get-NetAdapter { param($InterfaceIndex, $ErrorAction, [switch]$Physical) return [pscustomobject]@{ Name = 'Ethernet'; InterfaceGuid = '{0c0c0c0c-1111-2222-3333-444444444444}'; ifIndex = 5; Status = 'Up' } }
function Get-NetIPInterface { return [pscustomobject]@{ Dhcp = 'Enabled' } }
function Get-NetRoute { param($InterfaceIndex, $DestinationPrefix, $AddressFamily, $ErrorAction) if ($script:RouteFail) { Write-Error 'Route query failed' -ErrorAction $ErrorAction }; return $null }
function Remove-NetIPAddress { param($IPAddress, $InterfaceIndex, $PolicyStore, $Confirm, $ErrorAction) Write-Error 'Address removal failed' -ErrorAction $ErrorAction }
function netsh { return 'DHCP/Static IP coexistence : disabled' }
function Get-NetIPAddress { param($InterfaceIndex, $AddressFamily, $ErrorAction, $IPAddress) if ($script:AddrMode -eq 'none') { Write-Error -Message 'No MSFT_NetIPAddress objects found' -Category ObjectNotFound -ErrorAction $ErrorAction; return }; Write-Error 'Adapter address query failed' -ErrorAction $ErrorAction }
Run 'f08_raw_fail' { Reset; $script:FsNetOps = $null; $script:AddrMode = 'fail'; $script:RouteFail = $false
  $script:FsPcBefore = [pscustomobject]@{ ifIndex = 5; name = 'Ethernet'; guid = '{0c0c0c0c-1111-2222-3333-444444444444}'; dhcp = $true; coexist = 'disabled'; addrs = @([pscustomobject]@{ ip = '169.254.10.20'; skip = $false }); gw = @() }
  [void]$script:FsTemps.Add([pscustomobject]@{ ip = '192.168.0.253'; ifIndex = 5; p3 = '192.168.0' }); $f = JF 'f08b'; Save-FsNetState $f; $rr = Restore-FsPcNet $f
  [ordered]@{ ok = [bool]$rr.ok; journal = (Test-Path -LiteralPath $f); temps = @($script:FsTemps).Count; problems = (@($rr.problems) -join ' | ') } }
Run 'f08_raw_none' { Reset; $script:FsNetOps = $null; $script:AddrMode = 'none'; $script:RouteFail = $false
  $script:FsPcBefore = [pscustomobject]@{ ifIndex = 5; name = 'Ethernet'; guid = '{0c0c0c0c-1111-2222-3333-444444444444}'; dhcp = $true; coexist = 'disabled'; addrs = @([pscustomobject]@{ ip = '169.254.10.20'; skip = $false }); gw = @() }
  [void]$script:FsTemps.Add([pscustomobject]@{ ip = '192.168.0.253'; ifIndex = 5; p3 = '192.168.0' }); $f = JF 'f08c'; Save-FsNetState $f; $rr = Restore-FsPcNet $f
  [ordered]@{ ok = [bool]$rr.ok; journal = (Test-Path -LiteralPath $f); temps = @($script:FsTemps).Count; problems = (@($rr.problems) -join ' | ') } }
Run 'f08_reader_route' { Reset; $script:FsNetOps = $null; $script:AddrMode = 'none'; $script:RouteFail = $true; $s = Invoke-FsNetOp 'state' @{ ifIndex = 5 }; [ordered]@{ unread = (@(P $s 'unread') -join ', ') } }
$script:RouteFail = $false
Run 'f08_verify_incomplete' { Reset; New-Sim @{ dhcp = $false; unreadFrom = 2 }; [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '10.0.0.105'; prefix = 24; skip = $false }); $script:FsPcBefore = Before; $f = JF 'f08e'; Save-FsNetState $f; Res (Restore-FsPcNet $f) $f }
Run 'f08_dup_incomplete' { Reset; New-Sim @{ dhcp = $false; unreadFrom = 2; addResult = 'Duplicate'; removeWorks = $true }; $f = JF 'f08f'; $t = Add-FsTempIp '192.168.0' $pcS $f; $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; [ordered]@{ added = [string]$t; journalTemps = @($j.temps).Count; memTemps = @($script:FsTemps).Count } }
$script:FsNetOps = $null

# ---------------- F09 ----------------
function Damaged([string]$n, [string]$text) { Reset; New-Sim; $f = JF $n; [IO.File]::WriteAllText($f, $text); $rr = Clear-FsLeftoverTemps $f; $fl = Files $f
  return [ordered]@{ ok = $(if ($rr) { [bool]$rr.ok } else { $null }); blocked = [string]$script:FsNetBlocked; journal = (Test-Path -LiteralPath $f); marker = (@($fl | Where-Object { $_ -like '*.recovery-needed.json' }).Count -eq 1); kept = (@($fl | Where-Object { $_ -like '*.unreadable-*.json' }).Count -ge 1); writes = @($script:sim.writes) } }
Run 'f09_empty_obj' { Damaged 'f09a' '{}' }
Run 'f09_v2_bare' { Damaged 'f09b' '{"version":2}' }
Run 'f09_v3' { Damaged 'f09c' '{"version":3,"before":{"ifIndex":5,"name":"Ethernet","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]},"coexistChanged":false,"temps":[]}' }
Run 'f09_noname' { Damaged 'f09d' '{"version":2,"before":{"ifIndex":5,"dhcp":true,"coexist":"disabled","addrs":[],"gw":[]},"coexistChanged":true,"temps":[]}' }
Run 'f09_badip' { Damaged 'f09e' '{"version":2,"before":{"ifIndex":5,"name":"Original Ethernet","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]},"coexistChanged":false,"temps":[{"p3":"192.168.0","ip":"","ifIndex":5}]}' }
Run 'f09_emptylist' { Damaged 'f09f' '[]' }
Run 'f09_valid' { Reset; New-Sim; $f = JF 'f09g'; [IO.File]::WriteAllText($f, '{"version":2,"written":"2026-11-11T00:00:00","before":{"ifIndex":5,"name":"Original Ethernet","guid":"{0a0a0a0a-1111-2222-3333-444444444444}","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]},"coexistChanged":false,"temps":[]}')
  $rr = Clear-FsLeftoverTemps $f; [ordered]@{ ok = [bool]$rr.ok; blocked = [string]$script:FsNetBlocked; journal = (Test-Path -LiteralPath $f) } }
Run 'f09_next_start' { Reset; New-Sim; $f = JF 'f09a'; $rr = Clear-FsLeftoverTemps $f; $t = Add-FsTempIp '192.168.0' $pcA $f; [ordered]@{ ok = $(if ($rr) { [bool]$rr.ok } else { $null }); blocked = [string]$script:FsNetBlocked; added = [string]$t; writes = @($script:sim.writes) } }
# the decision: a restart alone never clears the block; every adapter must read completely and be normal
function Decide([string]$n, [scriptblock]$all) { Reset; New-Sim; $f = JF $n; [IO.File]::WriteAllText($f, '{}'); [void](Clear-FsLeftoverTemps $f)
  $mk = $f -replace '\.json$', '.recovery-needed.json'; $mj = Get-Content -LiteralPath $mk -Raw | ConvertFrom-Json; $mj.createdUtcTicks = [datetime]::UtcNow.AddHours(-2).Ticks; [IO.File]::WriteAllText($mk, (ConvertTo-Json -InputObject $mj)); foreach ($u in @(Get-ChildItem -LiteralPath (Split-Path -Parent $f) -File | Where-Object { $_.Name -like '*.unreadable-*.json' })) { $u.LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-2) }
  Reset; New-Sim; $script:FsNetOps['boottime'] = { param($a) return [datetime]::UtcNow.AddHours(-1) }; $script:FsNetOps['skipaddrs'] = { param($a) return [pscustomobject]@{ ips = @() } }; $script:FsNetOps['allstate'] = $all
  $rr = Clear-FsLeftoverTemps $f; return [ordered]@{ blocked = [string]$script:FsNetBlocked; cleared = (@(Files $f | Where-Object { $_ -like '*.recovery-cleared-*.json' }).Count -eq 1); marker = (Test-Path -LiteralPath $mk) } }
Run 'dec_coexist_on' { Decide 'deca' { param($a) [pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'Ethernet'; ifIndex = 5; state = [pscustomobject]@{ dhcp = $true; coexist = 'enabled'; addrs = @([pscustomobject]@{ ip = '192.168.1.105'; skip = $false }); gw = @('192.168.1.1'); unread = @() } }) } } }
Run 'dec_unread' { Decide 'decb' { param($a) return $null } }
Run 'dec_partial' { Decide 'decc' { param($a) [pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'Ethernet'; ifIndex = 5; state = [pscustomobject]@{ dhcp = $true; coexist = 'disabled'; addrs = @(); gw = @(); unread = @('the addresses') } }) } } }
Run 'dec_static_none' { Decide 'decd' { param($a) [pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'Ethernet'; ifIndex = 5; state = [pscustomobject]@{ dhcp = $false; coexist = 'disabled'; addrs = @(); gw = @(); unread = @() } }) } } }
Run 'dec_normal' { Decide 'dece' { param($a) [pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'Ethernet'; ifIndex = 5; state = [pscustomobject]@{ dhcp = $true; coexist = 'disabled'; addrs = @([pscustomobject]@{ ip = '192.168.1.105'; skip = $false }); gw = @('192.168.1.1'); unread = @() } }) } } }

# ---------------- F27 ----------------
$script:tries = 0
function Test-FsLoginOnce([string]$ip, [string]$brand, [string]$pw) { $script:tries++; $script:seen = $(if ($script:FsLoginLedger -and (Test-Path -LiteralPath $script:FsLoginLedger)) { [IO.File]::ReadAllText($script:FsLoginLedger) } else { '' }); if ($script:OnTry) { & $script:OnTry }; return $script:Answer }
function Led([string]$n, $text) { $d = Join-Path $D $n; New-Item -ItemType Directory -Force -Path $d | Out-Null; $f = Join-Path $d 'login-fails.json'; if ($null -ne $text) { [IO.File]::WriteAllText($f, $text) }; $script:FsLoginLedger = $f; $script:FsLoginFails = @{}; $script:FsLoginHold = @{}; $script:tries = 0; $script:seen = ''; $script:OnTry = $null; return $f }
Run 'f27_codex_budget' { $null = Led 'l1' '{truncated'; $b = Get-FsLoginBudget '192.168.1.50'; [ordered]@{ fails = [int]$b.fails; until = [string]$b.until; unknown = [string](P $b 'unknown') } }
Run 'f27_truncated_try' { $null = Led 'l2' '{truncated'; $script:Answer = 'refused'; $s = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'; [ordered]@{ state = $s; tries = $script:tries } }
Run 'f27_bad_entry' { $null = Led 'l3' '{"192.168.1.50":{"fails":"x","last":"2026-11-11T05:00:00.0000000Z"}}'; $script:Answer = 'refused'; $s = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'; [ordered]@{ state = $s; tries = $script:tries } }
Run 'f27_reserved' { $f = Led 'l4' $null; $script:Answer = 'refused'; $s = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'; $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
  [ordered]@{ state = $s; tries = $script:tries; seenDuringTry = $script:seen; after = [int]$o.'192.168.1.50'.fails } }
Run 'f27_unsavable' { $d = Join-Path $D 'l5'; New-Item -ItemType Directory -Force -Path $d | Out-Null; $blk = Join-Path $d 'afile'; [IO.File]::WriteAllText($blk, 'x'); $script:FsLoginLedger = Join-Path $blk 'login-fails.json'; $script:FsLoginFails = @{}; $script:FsLoginHold = @{}; $script:tries = 0; $script:OnTry = $null
  $script:Answer = 'refused'; $s = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'; [ordered]@{ state = $s; tries = $script:tries } }
Run 'f27_noanswer' { $f = Led 'l6' '{"192.168.1.50":{"fails":1,"last":"2026-01-01T05:00:00.0000000Z"}}'; $script:Answer = 'noanswer'; $s = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'; $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; [ordered]@{ state = $s; tries = $script:tries; after = [int]$o.'192.168.1.50'.fails } }
Run 'f27_refused_counts' { $f = Led 'l7' $null; $script:Answer = 'refused'; [void](Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'); [void](Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-2'); $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; [ordered]@{ tries = $script:tries; after = [int]$o.'192.168.1.50'.fails } }
Run 'f27_ok_clears' { $f = Led 'l8' $null; $script:Answer = 'refused'; [void](Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'); $script:Answer = 'ok'; $s = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-2'; $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; [ordered]@{ state = $s; entry = ($null -ne $o.PSObject.Properties['192.168.1.50']) } }
Run 'f27_save_fails_later' { if (-not $IsLinux) { return $null }; $f = Led 'l9' $null; $script:Answer = 'refused'; $dir = Split-Path -Parent $f
  $script:OnTry = { & chmod 500 $dir }
  $s1 = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-1'; $script:OnTry = $null; $t1 = $script:tries
  $s2 = Test-FsLogin '192.168.1.50' 'Hikvision' 'pw-test-2'; & chmod 700 $dir
  [ordered]@{ first = $s1; second = $s2; tries = $script:tries; triesAfterFirst = $t1 } }
'JSON=' + (ConvertTo-Json -Compress -Depth 6 -InputObject $R)

'@
$rnDrv = @'
function P($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { return $o.$k }; return $null }

$ErrorActionPreference = 'Continue'
$R = [ordered]@{}
function Run([string]$name, [scriptblock]$sb) { try { $R[$name] = (& $sb) } catch { $R[$name] = [ordered]@{ error = ($_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber) } } }
# one whole Invoke-RestoreNetwork run against a stand-in adapter; $o: coexist, dhcp, unread, journal (text), listSwap
function RnRun([string]$n, [hashtable]$o) {
  $dir = Join-Path $D $n; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $script:RnFixSiteState = Join-Path (Join-Path (Join-Path $dir 'fixsite-runs') '_state') 'fixsite-temp-ips.json'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:RnFixSiteState) | Out-Null
  if ($o.journal) { [IO.File]::WriteAllText($script:RnFixSiteState, [string]$o.journal) }
  $script:RnLines.Clear(); $script:RnDone.Clear(); if (Get-Variable -Name RnNotes -Scope Script -ErrorAction SilentlyContinue) { $script:RnNotes = @() }
  $script:t = @{ o = $o; ops = New-Object System.Collections.ArrayList; listN = 0 }
  $script:RnOps = { param($op, $a)
    [void]$script:t.ops.Add($op)
    switch ($op) {
      'list' { $script:t.listN++; $g = 'same-adapter'; if ($script:t.o.listSwap -and $script:t.listN -ge 2) { $g = 'another-adapter' }; return [pscustomobject]@{ name = 'Ethernet'; ifIndex = 5; desc = 'Ethernet'; disabled = $false; connected = $true; wifi = $false; guid = $g } }
      'state' { $s = [ordered]@{ dhcp = [bool]$script:t.o.dhcp; coexist = [string]$script:t.o.coexist; active = @([pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; origin = 'Dhcp' }); persistent = @(); routes = @(); dnsStatic = $false; dnsServers = @() }; if ($script:t.o.unread) { $s.unread = @($script:t.o.unread) }; return [pscustomobject]$s }
      'isadmin' { return $true }
      'task' { return 'none' }
      'online' { return [pscustomobject]@{ link = $true; ip = '192.168.1.105'; gw = '192.168.1.1'; gwPing = $true; dns = $true; http = $true; httpIf = 5 } }
      default { return $true }
    }
  }
  $code = @(Invoke-RestoreNetwork)[-1]
  return [ordered]@{ code = $code; said = (@($script:RnLines) -join "`n"); pending = (Test-Path -LiteralPath $script:RnFixSiteState); keptAside = [bool]@(Get-ChildItem -LiteralPath (Split-Path -Parent $script:RnFixSiteState) -Filter 'fixsite-temp-ips.unreadable-*.json').Count; writes = @($script:t.ops | Where-Object { $_ -in @('dhcp', 'coexist', 'removeaddr', 'removeroute', 'dnsreset', 'enable') }) }
}
# 2.2.20: the fixtures carry every field Fix this site writes (coexistChanged, before.addrs/gw); a record without them is damaged (R08 twin)
$j2 = '{"version":2,"before":{"ifIndex":5,"name":"Ethernet","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]},"coexistChanged":false,"temps":[]}'
Run 'rn_codex' { RnRun 'a' @{ dhcp = $true; coexist = 'unknown'; journal = $j2 } }
Run 'rn_unread' { RnRun 'b' @{ dhcp = $false; coexist = 'disabled'; unread = @('the live addresses') } }
Run 'rn_damaged' { RnRun 'c' @{ dhcp = $true; coexist = 'disabled'; journal = '{}' } }
Run 'rn_control' { RnRun 'd' @{ dhcp = $true; coexist = 'disabled'; journal = $j2 } }
Run 'rn_unknown_norecord' { RnRun 'e' @{ dhcp = $true; coexist = 'unknown' } }
Run 'rn_other_adapter' { RnRun 'f' @{ dhcp = $true; coexist = 'disabled'; journal = '{"version":2,"before":{"ifIndex":5,"name":"Old USB Ethernet","dhcp":true,"coexist":"enabled","addrs":[],"gw":[]},"coexistChanged":true,"temps":[]}' } }
Run 'rn_classic_noadapter' { $script:t0 = 1; $cj = Join-Path $D 'classic-temp-ips.json'; [IO.File]::WriteAllText($cj, '{"version":2,"temps":[],"pc":{"coexistence_before":null,"firewall_rule":false,"cleanup_task":true,"ifIndex":null,"alias":null,"dhcp":null,"ip":null,"gw":null}}'); Set-Variable -Name FixNvrState -Value $cj -Scope Script; $x = RnRun 'h' @{ dhcp = $true; coexist = 'disabled' }; Set-Variable -Name FixNvrState -Value '' -Scope Script; $x }
Run 'rn_swap' { RnRun 'g' @{ dhcp = $false; coexist = 'disabled'; listSwap = $true } }
# the production state reader, stand-ins only for the Windows commands
function Get-NetIPInterface { return [pscustomobject]@{ Dhcp = 'Enabled' } }
function Get-NetIPAddress { param($InterfaceIndex, $AddressFamily, $PolicyStore, $ErrorAction) if ($PolicyStore -eq 'ActiveStore') { Write-Error 'Adapter address query failed' -ErrorAction $ErrorAction; return }; Write-Error -Message 'No MSFT_NetIPAddress objects found' -Category ObjectNotFound -ErrorAction $ErrorAction }
function Get-NetRoute { param($InterfaceIndex, $DestinationPrefix, $PolicyStore, $ErrorAction) return $null }
function Get-DnsClientServerAddress { return [pscustomobject]@{ ServerAddresses = @() } }
function Get-ItemProperty { param($LiteralPath, $Name, $ErrorAction) return [pscustomobject]@{ NameServer = '' } }
function netsh { return 'DHCP/Static IP coexistence : disabled' }
Run 'rn_reader' { $script:RnOps = $null; $s = Invoke-RnOp 'state' @{ ifIndex = 5; guid = '{0c0c0c0c-1111-2222-3333-444444444444}' }; [ordered]@{ unread = (@(P $s 'unread') -join ', '); active = @($s.active).Count } }
'JSON=' + (ConvertTo-Json -Compress -Depth 6 -InputObject $R)

'@
$wwDrv = @'

$ErrorActionPreference = 'Continue'
$R = [ordered]@{}
function Run([string]$name, [scriptblock]$sb) { try { $R[$name] = (& $sb) } catch { $R[$name] = [ordered]@{ error = ($_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber) } } }
function WwCase([string]$n, [string]$content, [bool]$unreadable, $off, [bool]$enableWorks = $true) {
  $script:Dir = Join-Path $D $n; New-Item -ItemType Directory -Force -Path $script:Dir | Out-Null
  $script:log = Join-Path $script:Dir 'wifiwatch.log'; $script:marker = Join-Path $script:Dir 'adapter-off.txt'
  Set-Variable -Name Dir -Value $script:Dir -Scope Global; Set-Variable -Name log -Value $script:log -Scope Global; Set-Variable -Name marker -Value $script:marker -Scope Global
  [IO.File]::WriteAllText($script:marker, $content)
  if ($unreadable) { if ($IsLinux) { & chmod 000 $script:marker } else { return $null } }
  $script:wwCalls = New-Object System.Collections.ArrayList; $script:wwOff = $off; $script:wwEnable = $enableWorks
  $script:WwOps = { param($op, $a) [void]$script:wwCalls.Add($op); if ($op -eq 'wifioff') { if ($null -eq $script:wwOff) { return $null }; return [pscustomobject]@{ off = @($script:wwOff) } }; if ($op -eq 'isup') { return $script:wwEnable }; return $true }
  $ret = Repair-WwAdapter
  if ($unreadable -and $IsLinux) { & chmod 600 $script:marker 2>$null }
  $files = @(Get-ChildItem -LiteralPath $script:Dir -File | ForEach-Object { $_.Name })
  $lg = ''; try { $lg = [IO.File]::ReadAllText($script:log) } catch {}
  return [ordered]@{ ret = $ret; markerExists = (Test-Path -LiteralPath $script:marker); resolved = (@($files | Where-Object { $_ -like 'adapter-off.resolved-*.txt' }).Count -eq 1); ops = @($script:wwCalls); log = $lg }
}
Run 'ww_codex' { WwCase 'a' 'Wi-Fi' $true @('Wi-Fi') }
Run 'ww_empty' { WwCase 'b' '' $false @('Wi-Fi') }
Run 'ww_resolved' { WwCase 'c' '' $false @() }
Run 'ww_off_still' { WwCase 'd' '' $false @('Wi-Fi') }
Run 'ww_list_unread' { WwCase 'e' '' $false $null }
Run 'ww_control' { WwCase 'f' 'Wi-Fi' $false @() }
Run 'ww_enable_fails' { WwCase 'g' 'Wi-Fi' $false @() $false }
Run 'ww_pause_garbage' { $pf = Join-Path $D 'pause-g.txt'; [IO.File]::WriteAllText($pf, 'hello'); $script:PauseFile = $pf; $p = Test-WwPaused; [IO.File]::SetLastWriteTimeUtc($pf, [datetime]::UtcNow.AddMinutes(-45)); $q = Test-WwPaused; [ordered]@{ fresh = $p; old = $q } }
'JSON=' + (ConvertTo-Json -Compress -Depth 6 -InputObject $R)

'@

try {
  foreach ($f in @('Toolkit\FixSiteDevices.ps1', 'Toolkit\RestoreNetwork.ps1', 'wifiwatch\WifiWatch.ps1')) {
    $p = Join-Path $repo $f; $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('control: parses: ' + $f) ($e | Out-String)
  }
  $data = Join-Path $tmp 'data'; New-Item -ItemType Directory -Force -Path $data | Out-Null
  $pre = '$D = ' + (Q $data) + "`n"

  # =====================================================================================
  Write-Host 'F05 / F08 / F09 / F27 (Fix this site: the laptop''s adapter recovery, its record and the wrong-password count)'
  $o = Invoke-Driver 'site' ($pre + ". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n" + $siteDrv)
  $j = Get-Json $o; if (-not $j) { Write-Host $o.Substring([Math]::Max(0, $o.Length - 3000)) }
  $r = P $j 'f05_changed'
  Check ($r -and -not $r.ok -and -not @($r.writes).Count -and $r.journal -and $r.problems -match 'another adapter') 'F05 another adapter took the saved number (different ID): nothing is changed on it, the record is kept, the reason says so (2.2.18 enabled DHCP on it, ok=true, record deleted)' $r
  $r = P $j 'f05_codex'
  Check ($r -and -not $r.ok -and -not @($r.writes).Count -and $r.journal) 'F05 Codex repro "changed adapter" (replacement Wi-Fi at the saved index): no DHCP write, ok=false, journal kept' $r
  $r = P $j 'f05_identfail'
  Check ($r -and -not $r.ok -and -not @($r.writes).Count -and $r.journal -and $r.temps -eq 1) 'F05 which adapter is at the number cannot be read: no address removed, no setting changed, record and temporary address kept (unread identity keeps the block)' $r
  $r = P $j 'f05_same'
  Check ($r -and $r.ok -and -not $r.journal) 'control: the same adapter (ID and name match), nothing left to change: recovered, record done' $r
  $r = P $j 'f05_noguid_same'
  Check ($r -and $r.ok -and -not $r.journal) 'control: a record from before 2.2.19 (no adapter ID) with the same adapter name: recovered' $r
  Check ($r -and $r.log -match 'name only') 'F05 ...and the log says it was matched by the adapter name only (no ID in that record)' $r
  $r = P $j 'f05_noguid_other'
  Check ($r -and -not $r.ok -and -not @($r.writes).Count -and $r.journal -and $r.problems -match 'Ethernet 2') 'F05 a record without an ID and another adapter name at that number: nothing changed, record kept, the adapter named' $r
  $r = P $j 'f05_swap_midway'
  Check ($r -and -not $r.ok -and (@($r.writes) -join ',') -eq 'remove 192.168.0.253' -and $r.journal) 'F05 twin: the adapter is identified again before EACH change - it changed half-way (after the temporary address came off), so no setting is written to the other adapter' $r
  $r = P $j 'f05_add_identfail'
  Check ($r -and -not $r.added -and -not @($r.writes).Count) 'F05 twin (journal writer Add-FsTempIp): the adapter cannot be identified -> no temporary address and no coexistence change' $r
  $r = P $j 'f05_add_saves_guid'
  Check ($r -and $r.added -and $r.guid -eq '{0a0a0a0a-1111-2222-3333-444444444444}' -and $r.name -eq 'Original Ethernet') 'F05 the record saves the adapter''s stable ID (InterfaceGuid) with its name before anything changes' $r
  $r = P $j 'f05_add_coexist_unknown'
  Check ($r -and -not $r.added -and -not @($r.writes).Count) 'F05/D twin: a DHCP adapter whose coexistence setting cannot be read gets no temporary address (2.2.18 took unknown as off and turned it OFF at the end)' $r
  $r = P $j 'f05_dup_swap'
  Check ($r -and -not $r.added -and -not @($r.writes | Where-Object { $_ -like 'remove*' }).Count -and [int]$r.journalTemps -eq 1) 'F05 twin (Remove-FsOneTempChecked): taking a duplicate address back off is refused when another adapter answers at the number; it stays in the record' $r

  $r = P $j 'f08_codex_null'
  Check ($r -and -not $r.ok -and $r.journal -and [int]$r.temps -eq 1 -and $r.before) 'F08 Codex repro "unread adapter" (null-state contract): a state read that answers nothing keeps the record, the temporary address and the saved settings (2.2.18: ok, all cleared)' $r
  $r = P $j 'f08_raw_fail'
  Check ($r -and -not $r.ok -and $r.journal -and [int]$r.temps -eq 1 -and $r.problems -match 'could not') 'F08 Codex repro "raw adapter queries fail": the real Invoke-FsNetOp state reader with a failing address query and a failing removal -> NOT back, record and address kept' $r
  $r = P $j 'f08_raw_none'
  Check ($r -and $r.ok -and -not $r.journal) 'control: the real state reader when Windows answers "no matching address" (a real empty list): recovered' $r
  $r = P $j 'f08_reader_route'
  Check ($r -and $r.unread -match 'router') 'F08 the real state reader names a failed router query as unread (it is not "no router")' $r
  $r = P $j 'f08_verify_incomplete'
  Check ($r -and -not $r.ok -and $r.journal) 'F08 twin: the check after recovery is incomplete (addresses unread) -> not "back", record kept' $r
  $r = P $j 'f08_dup_incomplete'
  Check ($r -and [int]$r.journalTemps -ge 1 -and [int]$r.memTemps -ge 1) 'F08 twin (Remove-FsOneTempChecked): "the address is gone" only from a complete read - an incomplete read keeps it in the record' $r

  foreach ($c in @(@('f09_empty_obj', 'Codex repro: {}'), @('f09_v2_bare', '{"version":2} with nothing else'), @('f09_v3', 'an unknown version (3)'), @('f09_noname', 'no adapter name'), @('f09_badip', 'a temporary address without a valid IP'), @('f09_emptylist', 'an empty list []'))) {
    $r = P $j $c[0]
    $pre9 = $(if ($c[0] -eq 'f09_emptylist') { 'control (already blocked in 2.2.18): ' } else { 'F09 ' })
    Check ($r -and $r.ok -eq $false -and $r.blocked -and $r.marker -and $r.kept -and -not $r.journal -and -not @($r.writes).Count) ($pre9 + 'a readable but damaged record (' + $c[1] + '): quarantined (kept as .unreadable-*), the durable block written, nothing changed, not ok') $r
  }
  $r = P $j 'f09_valid'
  Check ($r -and $r.ok -and -not $r.blocked -and -not $r.journal) 'control: a complete version-2 record is recovered normally' $r
  $r = P $j 'f09_next_start'
  Check ($r -and $r.blocked -and -not $r.added -and -not @($r.writes).Count) 'F09 the next start after a damaged record is still blocked: no temporary address added' $r

  $r = P $j 'dec_coexist_on'
  Check ($r -and $r.blocked -and $r.marker -and -not $r.cleared) 'decision: restarted since and no temporary address, but an adapter still has coexistence on -> still blocked (2.2.18 cleared it on the restart)' $r
  $r = P $j 'dec_unread'
  Check ($r -and $r.blocked -and $r.marker) 'decision: restarted, but the adapters cannot be read -> still blocked (never cleared on a guess)' $r
  $r = P $j 'dec_partial'
  Check ($r -and $r.blocked -and $r.marker) 'decision: restarted, but an adapter''s settings read incompletely -> still blocked' $r
  $r = P $j 'dec_static_none'
  Check ($r -and $r.blocked -and $r.marker) 'decision: restarted, but an adapter has DHCP off and no address -> still blocked (run Restore Network)' $r
  $r = P $j 'dec_normal'
  Check ($r -and -not $r.blocked -and $r.cleared -and -not $r.marker) 'decision: restarted AND every adapter read completely and normal -> the block is cleared (renamed, kept)' $r

  $r = P $j 'f27_codex_budget'
  Check ($r -and [int]$r.fails -ge 4 -and $r.unknown) 'F27 Codex repro "unread login ledger": a truncated count file = unknown budget, the device counts as spent (2.2.18: fails=0)' $r
  $r = P $j 'f27_truncated_try'
  Check ($r -and $r.state -eq 'locked' -and [int]$r.tries -eq 0) 'F27 ...and no password is sent to that device (held, plain reason)' $r
  $r = P $j 'f27_bad_entry'
  Check ($r -and $r.state -eq 'locked' -and [int]$r.tries -eq 0) 'F27 a count file with a damaged entry (fails "x"): held, no password sent' $r
  $r = P $j 'f27_reserved'
  Check ($r -and [int]$r.tries -eq 1 -and $r.seenDuringTry -match '"fails":\s*1' -and [int]$r.after -eq 1) 'F27 the try is written down (count 1) BEFORE the password is sent, and kept after a refusal' $r
  $r = P $j 'f27_unsavable'
  Check ($r -and $r.state -eq 'locked' -and [int]$r.tries -eq 0) 'F27 the count cannot be saved (its folder cannot be made): the password is not sent' $r
  $r = P $j 'f27_noanswer'
  Check ($r -and [int]$r.tries -eq 1 -and [int]$r.after -eq 1) 'control: a try with no answer does not count as a wrong password' $r
  $r = P $j 'f27_refused_counts'
  Check ($r -and [int]$r.tries -eq 2 -and [int]$r.after -eq 2) 'control: two refused tries are counted 2 on disk' $r
  $r = P $j 'f27_ok_clears'
  Check ($r -and $r.state -eq 'ok' -and -not $r.entry) 'control: a password that works clears the device''s count' $r
  if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
    $r = P $j 'f27_save_fails_later'
    Check ($r -and $r.first -eq 'refused' -and $r.second -eq 'locked' -and [int]$r.tries -eq 1) 'F27 the count could not be saved after a refused try: that device is held for the rest of the run (no second password)' $r
  } else { $script:deferred++; Write-Host 'DEFERRED F27 save failure after a refused try (needs a folder made read-only by chmod; Linux test box only)' }

  # =====================================================================================
  Write-Host 'F18 (Restore Network: an unreadable relevant setting is NOT CHECKED, never DONE)'
  $rd = Join-Path $tmp 'rn'
  $o = Invoke-Driver 'rn' ($pre + ". " + (Q (Join-Path $tk 'RestoreNetwork.ps1')) + " -ToolkitDir " + (Q $rd) + " -ReceiptDir " + (Q (Join-Path $rd 'receipts')) + " -FixNvrState " + (Q (Join-Path $rd 'no-classic.json')) + " -NoElevate -Auto -OnlineSeconds 0`n" + $rnDrv)
  $j = Get-Json $o; if (-not $j) { Write-Host $o.Substring([Math]::Max(0, $o.Length - 3000)) }
  $r = P $j 'rn_codex'
  Check ($r -and [int]$r.code -ne 0 -and $r.said -notmatch 'DONE' -and $r.said -match 'NOT CHECKED' -and $r.pending) 'F18 Codex repro "unread coexistence": the record says off, the read says unknown -> NOT CHECKED, FAILED, the record stays pending (2.2.18: DONE, exit 0)' $r
  $r = P $j 'rn_unread'
  Check ($r -and [int]$r.code -eq 6 -and $r.said -notmatch 'DONE' -and -not @($r.writes).Count) 'F18 twin: the adapter''s settings cannot be fully read -> nothing is changed (a failed read is not "DHCP off"), FAILED' $r
  $r = P $j 'rn_damaged'
  Check ($r -and [int]$r.code -ne 0 -and $r.said -notmatch 'DONE' -and $r.said -match 'NOT CHECKED' -and ($r.pending -or $r.keptAside) -and -not @($r.writes).Count) 'F09/F18 twin: a damaged Toolkit record ({}) is NOT CHECKED, never DONE; it is not renamed as done (2.2.20: kept aside as .unreadable-, the durable block Fix this site reads; nothing changed)' $r
  $r = P $j 'rn_control'
  Check ($r -and [int]$r.code -eq 0 -and $r.said -match 'DONE' -and -not $r.pending) 'control: coexistence reads off as the record says: DONE, the record is done' $r
  $r = P $j 'rn_unknown_norecord'
  Check ($r -and [int]$r.code -eq 0 -and $r.said -match 'not checked') 'F18: with no Toolkit record, an unreadable coexistence setting is said as not checked on the DONE run' $r
  $r = P $j 'rn_other_adapter'
  Check ($r -and -not @($r.writes | Where-Object { $_ -eq 'coexist' }).Count -and $r.pending) 'F05 twin: a record naming another adapter at the same number is not applied to this one (no coexistence write) and not marked done' $r
  $r = P $j 'rn_classic_noadapter'
  Check ($r -and [int]$r.code -eq 0 -and $r.said -match 'DONE') 'control: a Fix NVR record from before any adapter change (no addresses, no adapter yet) is a real empty record, not "damaged"' $r
  $r = P $j 'rn_swap'
  Check ($r -and -not @($r.writes).Count -and [int]$r.code -ne 0) 'F05 twin: the adapter is identified again right before each change; another adapter answers at the number -> not changed, FAILED' $r
  $r = P $j 'rn_reader'
  Check ($r -and $r.unread -match 'live addresses' -and $r.unread -notmatch 'saved addresses') 'F18/F08 twin: the real Restore Network state reader names a failed address query as unread, and a real "none found" as empty' $r

  # =====================================================================================
  Write-Host 'F21 (WifiWatch: an unreadable adapter-off marker is kept and stays the block)'
  $wd = Join-Path $tmp 'ww'; New-Item -ItemType Directory -Force -Path $wd | Out-Null
  $o = Invoke-Driver 'ww' ($pre + ". " + (Q (Join-Path $repo 'wifiwatch\WifiWatch.ps1')) + " -Dir " + (Q $wd) + " -PauseFile " + (Q (Join-Path $wd 'no-pause')) + "`n" + $wwDrv)
  $j = Get-Json $o; if (-not $j) { Write-Host $o.Substring([Math]::Max(0, $o.Length - 3000)) }
  if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
    $r = P $j 'ww_codex'
    Check ($r -and $r.markerExists -and $r.ret -eq $false -and $r.log -match 'RECOVERY NOT DONE') 'F21 Codex repro "unread Wi-Fi marker" (no read permission): the marker is KEPT, the failed recovery is logged, the block stands (2.2.18 deleted it)' $r
  } else { $script:deferred++; Write-Host 'DEFERRED F21 marker without read permission (chmod 000; Linux test box only - the empty-marker checks below cover the same path)' }
  $r = P $j 'ww_empty'
  Check ($r -and $r.markerExists -and $r.ret -eq $false -and -not @($r.ops | Where-Object { $_ -eq 'enable' }).Count) 'F21 a marker with no adapter name and a Wi-Fi adapter still off: kept, blocked, nothing guessed' $r
  $r = P $j 'ww_resolved'
  Check ($r -and $r.ret -eq $true -and -not $r.markerExists -and $r.resolved) 'F21 checked recovery: every Wi-Fi adapter reads as on -> the marker is set aside as adapter-off.resolved-*.txt (kept, not deleted)' $r
  $r = P $j 'ww_list_unread'
  Check ($r -and $r.markerExists -and $r.ret -eq $false) 'F21 the adapters cannot be read: the unreadable marker stays the block' $r
  $r = P $j 'ww_control'
  Check ($r -and -not $r.markerExists -and @($r.ops) -contains 'enable') 'control: a readable marker - the adapter is switched back on and the marker removed' $r
  $r = P $j 'ww_enable_fails'
  Check ($r -and $r.markerExists) 'control: the adapter does not come back on - the marker is kept for the next run' $r
  $r = P $j 'ww_pause_garbage'
  Check ($r -and $r.fresh -eq $true -and $r.old -eq $false) 'C/E twin: a pause file that cannot be read but was written in the last 30 min counts as paused (Restore Network may be working); an older one is ignored (2.2.18 ignored it at once)' $r
  $wsrc = [IO.File]::ReadAllText((Join-Path $repo 'wifiwatch\WifiWatch.ps1'))
  $iR = $wsrc.IndexOf('if (-not (Repair-WwAdapter)) {'); $iP = $wsrc.IndexOf("`nif (Test-WwPaused) {"); $iF = $wsrc.IndexOf("`n`$fails = 0")
  Check ($iR -gt 0 -and $iP -gt $iR -and $iF -gt $iP) 'F21 the watcher does nothing else (no reconnect, no adapter off/on) while a recovery is unfinished: the repair result ends the run first'

  # =====================================================================================
  Write-Host 'Windows PowerShell 5.1 rules in the changed files'
  foreach ($f in @('Toolkit\FixSiteDevices.ps1', 'Toolkit\RestoreNetwork.ps1', 'wifiwatch\WifiWatch.ps1')) {
    $p = Join-Path $repo $f; $tok = $null; $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$tok, [ref]$e)
    $bad = @($tok | Where-Object { $_.Kind -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr') -or ($_.Kind -eq 'QuestionMark') })
    $ter = @($ast.FindAll({ param($a) $a.GetType().Name -eq 'TernaryExpressionAst' -or $a.GetType().Name -eq 'PipelineChainAst' }, $true))
    Check (-not $bad.Count -and -not $ter.Count) ('5.1 syntax: no ??, ?., ternary, && or || in ' + $f) (@($bad | ForEach-Object { $_.Text + ' line ' + $_.Extent.StartLineNumber }) -join ', ')
  }
  $script:deferred++; Write-Host 'DEFERRED a real Windows laptop: Get-NetAdapter -InterfaceIndex / InterfaceGuid, Get-NetIPAddress and Get-NetRoute failing vs "none found" (CIM ObjectNotFound), a real adapter replaced at the same index, and Windows PowerShell 5.1 (NEEDS WINDOWS CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Get-ChildItem -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { if ($IsLinux) { & chmod u+rwx $_.FullName 2>$null } }; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('RESULT: Test-Fix2219PcNet: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
exit $script:fail
