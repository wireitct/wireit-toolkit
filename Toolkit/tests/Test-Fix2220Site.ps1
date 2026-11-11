<# Test-Fix2220Site.ps1 - WireIt Toolkit 2.2.20, Fix this site (Codex review of 2.2.19, head ca8d5b3): R01 (the network journal and
   its recovery marker are saved TERMINATING and READ BACK before any adapter change; an orphan <journal>.tmp is evidence at the next
   start), R04 (an unreadable neighbour table is "not known", never "free"), R09 site twin (missing router / DNS is not an empty value;
   a DNS asked for must be in the written and the read-back document; Undo needs every old value), R12 site twin (a password check
   needs the authenticated DeviceInfo / type document AND the saved device's MAC, not HTTP 200), R13 (an uncertain login try stays
   counted; only a try that never left this PC gives its count back) and the class sweep twins in the same files (Fs-HikOk on a 200
   login page, the site secret store and undo file read back, Wait-FsDevice not spending tries on a restarting device).
   The real FixSiteCore.ps1 / FixSiteDevices.ps1 are loaded in their own PowerShell process per group; only Windows' network commands,
   HTTP answers and selected persistence failures are stand-ins (as in Codex's reproductions). Checks marked "Codex repro" rebuild
   Codex's reproduce.ps1 / reproduce-real-save.ps1 / reproduce-safety.ps1 lines. Checks marked "control" pass on old and new code.
   A check that only reads source text says "(code shape)". FIX2220SITE_REPO = another checkout (e.g. 2.2.19 ca8d5b3) to prove the
   finding checks fail there. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2220SITE_REPO) { $repo = $env:FIX2220SITE_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2220site-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, $more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = $(if ($more -is [string]) { $more } else { ConvertTo-Json -Compress -Depth 6 -InputObject $more }); Write-Host ('     ' + ($m -replace "`n", "`n     ")) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function P($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { return $o.$k }; return $null }

$head = @'
$ErrorActionPreference = 'Continue'
$script:Log = New-Object System.Collections.ArrayList
$R = [ordered]@{}
function Run([string]$name, [scriptblock]$sb) { try { $R[$name] = (& $sb) } catch { $R[$name] = [ordered]@{ error = ($_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber) } } }
'@
$load = $head + "`n" + '. ' + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "`n" + '. ' + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n" + 'function Fs-LogLine([string]$s) { [void]$script:Log.Add($s) }' + "`n" + '$D = ' + (Q $tmp) + "`n"

# ======================= R01: the network journal (class A) =======================
$r01 = $load + @'
function JF([string]$n) { $f = Join-Path (Join-Path $D $n) 'fixsite-temp-ips.json'; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null; return $f }
function Reset { $script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $script:FsNetBlocked = $null; $script:Log.Clear(); $script:FsRestoreChecks = 1; $script:FsMockUrl = '' }
function New-Ops {
  $script:sim = @{ writes = New-Object System.Collections.ArrayList; addrs = New-Object System.Collections.ArrayList }
  $script:FsNetOps = @{
    state = { param($a) [pscustomobject]@{ dhcp = $false; coexist = 'disabled'; addrs = @(@([pscustomobject]@{ ip = '10.0.0.10'; prefix = 24; skip = $false }) + @($script:sim.addrs)); gw = @(); unread = @() } }
    ident = { param($a) [pscustomobject]@{ name = 'Ethernet'; guid = 'guid-a' } }
    free = { param($a) $true }
    addtemp = { param($a) [void]$script:sim.writes.Add('addtemp ' + $a.ip); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = 24; skip = $true }); 'Preferred' }
    remove = { param($a) [void]$script:sim.writes.Add('remove ' + $a.ip); foreach ($x in @($script:sim.addrs | Where-Object { $_.ip -eq $a.ip })) { $script:sim.addrs.Remove($x) }; $true }
    dhcp = { param($a) [void]$script:sim.writes.Add('dhcp'); $true }; coexist = { param($a) [void]$script:sim.writes.Add('coexist'); $true }
    addstatic = { param($a) [void]$script:sim.writes.Add('addstatic ' + $a.ip); $true }; addroute = { param($a) [void]$script:sim.writes.Add('addroute'); $true }
    renew = { param($a) $true }; wait = { param($a) $true }
    boottime = { param($a) (Get-Date).AddDays(-1) }; skipaddrs = { param($a) [pscustomobject]@{ ips = @() } }; allstate = { param($a) [pscustomobject]@{ adapters = @() } }
  }
}
$pc = [pscustomobject]@{ ifIndex = 5; name = 'Ethernet' }
# Codex reproduce.ps1 "site-save-failed": the final move answers a NON-terminating error under the caller's Continue
Run 'movedenied' {
  Reset; New-Ops; $j = JF 'movedenied'
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force) Write-Error 'journal final move denied' }
  $a = Add-FsTempIp '192.168.99' $pc $j
  Remove-Item function:Move-Item
  [ordered]@{ returned = [string]$a; writes = @($script:sim.writes).Count; journal = (Test-Path -LiteralPath $j) }
}
# a move that reports nothing but does not put the file in place: only a read back can tell
Run 'movesilent' {
  Reset; New-Ops; $j = JF 'movesilent'
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force) }
  $a = Add-FsTempIp '192.168.99' $pc $j
  Remove-Item function:Move-Item
  [ordered]@{ returned = [string]$a; writes = @($script:sim.writes).Count; journal = (Test-Path -LiteralPath $j) }
}
# control: a normal save works and the address goes on with its journal on disk
Run 'control' {
  Reset; New-Ops; $j = JF 'control'
  $a = Add-FsTempIp '192.168.99' $pc $j
  $jj = $null; try { $jj = Get-Content -LiteralPath $j -Raw | ConvertFrom-Json } catch {}
  [ordered]@{ returned = [string]$a; writes = @($script:sim.writes).Count; listed = [bool]($jj -and @($jj.temps | Where-Object { $_.ip -eq $a }).Count) }
}
# Codex reproduce-real-save.ps1: a real directory-permission failure (Linux chmod; Windows ACLs stay deferred)
Run 'realdenied' {
  if ($env:OS -eq 'Windows_NT') { return [ordered]@{ skipped = $true } }
  Reset; New-Ops; $dir = Join-Path $D 'readonly'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $j = Join-Path $dir 'state.json'
  [IO.File]::WriteAllText("$j.tmp", 'temporary file preexists and is writable')
  try { & /bin/chmod 555 $dir; $a = Add-FsTempIp '192.168.99' $pc $j } finally { & /bin/chmod 755 $dir }
  [ordered]@{ skipped = $false; returned = [string]$a; writes = @($script:sim.writes).Count; journal = (Test-Path -LiteralPath $j) }
}
# an orphan <journal>.tmp (a run stopped between writing it and putting it in place) is taken into the recovery at the next start
Run 'orphanvalid' {
  Reset; New-Ops; $j = JF 'orphanvalid'
  [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.99.253'; prefix = 24; skip = $true })
  $o = [ordered]@{ version = 2; written = '2026-11-11T02:00:00'; before = [ordered]@{ ifIndex = 5; name = 'Ethernet'; guid = 'guid-a'; dhcp = $false; coexist = 'disabled'; addrs = @([ordered]@{ ip = '10.0.0.10'; prefix = 24; skip = $false }); gw = @() }; coexistChanged = $false; temps = @([ordered]@{ p3 = '192.168.99'; ip = '192.168.99.253'; ifIndex = 5 }) }
  [IO.File]::WriteAllText("$j.tmp", ($o | ConvertTo-Json -Depth 6))
  $r = Clear-FsLeftoverTemps $j
  [ordered]@{ removed = [bool](@($script:sim.writes) -contains 'remove 192.168.99.253'); stillOn = [bool]@($script:sim.addrs | Where-Object { $_.ip -eq '192.168.99.253' }).Count; ok = [bool]($r -and $r.ok); tmpLeft = (Test-Path -LiteralPath "$j.tmp") }
}
# an orphan .tmp beside a journal: its extra temporary address is merged in and taken off too
Run 'orphanmerge' {
  Reset; New-Ops; $j = JF 'orphanmerge'
  [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.99.253'; prefix = 24; skip = $true }); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.99.252'; prefix = 24; skip = $true })
  $b = [ordered]@{ ifIndex = 5; name = 'Ethernet'; guid = 'guid-a'; dhcp = $false; coexist = 'disabled'; addrs = @([ordered]@{ ip = '10.0.0.10'; prefix = 24; skip = $false }); gw = @() }
  [IO.File]::WriteAllText($j, ([ordered]@{ version = 2; written = 'x'; before = $b; coexistChanged = $false; temps = @([ordered]@{ p3 = '192.168.99'; ip = '192.168.99.253'; ifIndex = 5 }) } | ConvertTo-Json -Depth 6))
  [IO.File]::WriteAllText("$j.tmp", ([ordered]@{ version = 2; written = 'y'; before = $b; coexistChanged = $false; temps = @([ordered]@{ p3 = '192.168.99'; ip = '192.168.99.253'; ifIndex = 5 }, [ordered]@{ p3 = '192.168.99'; ip = '192.168.99.252'; ifIndex = 5 }) } | ConvertTo-Json -Depth 6))
  $r = Clear-FsLeftoverTemps $j
  [ordered]@{ removed252 = [bool](@($script:sim.writes) -contains 'remove 192.168.99.252'); removed253 = [bool](@($script:sim.writes) -contains 'remove 192.168.99.253'); ok = [bool]($r -and $r.ok) }
}
# a damaged orphan .tmp: kept as evidence under the durable block, nothing changed on the adapter
Run 'orphanbad' {
  Reset; New-Ops; $j = JF 'orphanbad'
  [IO.File]::WriteAllText("$j.tmp", '{"version":2,"before":')
  $r = Clear-FsLeftoverTemps $j
  $files = @(Get-ChildItem -LiteralPath (Split-Path -Parent $j) -File | ForEach-Object { $_.Name })
  # a second start is blocked too (durable, on disk)
  Reset; New-Ops; $r2 = Clear-FsLeftoverTemps $j
  [ordered]@{ blocked = [bool]$script:FsNetBlocked; ok = [bool]($r -and $r.ok); marker = [bool]@($files | Where-Object { $_ -like '*.recovery-needed.json' }).Count; kept = [bool]@($files | Where-Object { $_ -like '*.unreadable-*' }).Count; second = [bool]($r2 -and -not $r2.ok); writes = @($script:sim.writes).Count }
}
# R01 twin: the durable recovery marker - a refused move is not "written"
Run 'marker' {
  Reset; $j = JF 'marker'
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force) Write-Error 'marker move denied' }
  $threw = $false; try { [void](Set-FsNetRecoveryMarker $j 'x.json' ((Get-Date).ToUniversalTime())) } catch { $threw = $true }
  Remove-Item function:Move-Item
  [ordered]@{ threw = $threw; exists = (Test-Path -LiteralPath (Get-FsNetMarkerPath $j)) }
}
# R01 twin (class A sweep): the site secret store (old passwords for Undo) must read back as written
Run 'secrets' {
  $script:FsTestSecrets = $true; $dir = Join-Path $D 'vault'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $sec = [pscustomobject]@{ site = 'Review'; password = 'Site1234'; known = @(); nvr = @{}; cams = @{}; rollback = @{}; bitwardenSaved = $false; shownOnce = $true }
  Save-FsSecrets $dir $sec
  $sec.password = 'Changed5678'
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force) }
  $threw = $false; try { Save-FsSecrets $dir $sec } catch { $threw = $true }
  Remove-Item function:Move-Item
  [ordered]@{ threw = $threw }
}
'JSON=' + (ConvertTo-Json -Compress -Depth 8 -InputObject $R)
'@
$o = Invoke-Driver 'r01' $r01; $j = Get-Json $o
if (-not $j) { Check $false 'R01 driver ran' $o } else {
  $x = P $j 'movedenied'; Check ((P $x 'writes') -eq 0 -and -not (P $x 'returned')) 'R01 Codex repro site-save-failed: a refused final journal move (non-terminating, caller Continue) adds NO address' $x
  $x = P $j 'movesilent'; Check ((P $x 'writes') -eq 0 -and -not (P $x 'returned')) 'R01 a journal that is not in place after the save (read back) adds NO address' $x
  $x = P $j 'control'; Check ((P $x 'writes') -eq 1 -and (P $x 'returned') -eq '192.168.99.253' -and (P $x 'listed')) 'R01 control: a good save adds the address with it journaled' $x
  $x = P $j 'realdenied'
  if (P $x 'skipped') { Deferred 'R01 Codex repro native-journal-move-denied (a real read-only folder; Windows ACL behaviour NEEDS WINDOWS CHECK)' }
  else { Check ((P $x 'writes') -eq 0 -and -not (P $x 'returned') -and -not (P $x 'journal')) 'R01 Codex repro native-journal-move-denied: a real folder-permission failure adds NO address' $x }
  $x = P $j 'orphanvalid'; Check ((P $x 'removed') -and -not (P $x 'stillOn') -and (P $x 'ok') -and -not (P $x 'tmpLeft')) 'R01 an orphan journal .tmp (no journal) is taken into the next start''s recovery: its temporary address is taken off' $x
  $x = P $j 'orphanmerge'; Check ((P $x 'removed252') -and (P $x 'removed253') -and (P $x 'ok')) 'R01 an orphan .tmp beside the journal is merged: the address only it lists is taken off too' $x
  $x = P $j 'orphanbad'; Check ((P $x 'blocked') -and -not (P $x 'ok') -and (P $x 'marker') -and (P $x 'kept') -and (P $x 'second') -and (P $x 'writes') -eq 0) 'R01 a damaged orphan .tmp is kept as evidence under the durable block (this start and the next), no adapter change' $x
  $x = P $j 'marker'; Check ((P $x 'threw') -and -not (P $x 'exists')) 'R01 twin: the durable recovery marker - a refused move throws, never counts as written' $x
  $x = P $j 'secrets'; Check ([bool](P $x 'threw')) 'R01 twin (class A sweep): the site secret store that does not read back as saved throws (the change it protects is not made)' $x
}

# ======================= R04: free-address reader (class C) =======================
$r04 = $load + @'
function New-Object { param($TypeName) if ($TypeName -eq 'Net.NetworkInformation.Ping') { $p = [pscustomobject]@{}; $p | Add-Member -MemberType ScriptMethod -Name Send -Value { param($ip, $ms) [pscustomobject]@{ Status = 'TimedOut' } }; return $p }; Microsoft.PowerShell.Utility\New-Object $TypeName }
$script:FsNetOps = $null; $script:FsMockUrl = ''
# Codex reproduce.ps1 "site-free-on-query-error"
function Get-NetNeighbor { [CmdletBinding()]param($IPAddress, $AddressFamily) Write-Error 'neighbor provider unavailable' }
Run 'qerr' { [ordered]@{ free = [bool](Test-FsIpFree '127.0.0.77') } }
Run 'qerrmove' { $s = Get-FsMoveTargetState '127.0.0.77' 'Hikvision' '' '' ''; [ordered]@{ state = [string]$s.state; why = [string]$s.why } }
Run 'qerrnvr' { [ordered]@{ target = [string](Get-FsNvrMoveTarget '127.0.0.77' '127.0.0' @() @()) } }
# control: Windows' "no matching MSFT_NetNeighbor" (no entry) = readable empty = free
function Get-NetNeighbor { [CmdletBinding()]param($IPAddress, $AddressFamily) $e = [Management.Automation.ErrorRecord]::new([Exception]::new('No matching MSFT_NetNeighbor objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetNeighbor class'), 'CmdletizationQuery_NotFound', [Management.Automation.ErrorCategory]::ObjectNotFound, $IPAddress); $PSCmdlet.WriteError($e) }
Run 'notfound' { [ordered]@{ free = [bool](Test-FsIpFree '127.0.0.78') } }
# control: a live neighbour entry = taken
function Get-NetNeighbor { [CmdletBinding()]param($IPAddress, $AddressFamily) [pscustomobject]@{ IPAddress = $IPAddress; State = 'Reachable'; LinkLayerAddress = 'AA-BB-CC-00-00-01' } }
Run 'taken' { [ordered]@{ free = [bool](Test-FsIpFree '127.0.0.79') } }
'JSON=' + (ConvertTo-Json -Compress -Depth 8 -InputObject $R)
'@
$o = Invoke-Driver 'r04' $r04; $j = Get-Json $o
if (-not $j) { Check $false 'R04 driver ran' $o } else {
  $x = P $j 'qerr'; Check ((P $x 'free') -eq $false) 'R04 Codex repro site-free-on-query-error: no ping answer + a failed neighbour read is NOT free' $x
  $x = P $j 'qerrmove'; Check ((P $x 'state') -eq 'unknown' -and (P $x 'why')) 'R04 twin: the move-destination gate (forward and Undo) says unknown with the reason, never free' $x
  $x = P $j 'qerrnvr'; Check (-not (P $x 'target')) 'R04 twin: the NVR move target is not picked from an unreadable occupancy read' $x
  $x = P $j 'notfound'; Check ((P $x 'free') -eq $true) 'R04 control: "no matching MSFT_NetNeighbor" (no entry, readable) is free' $x
  $x = P $j 'taken'; Check ((P $x 'free') -eq $false) 'R04 control: a live neighbour entry is taken' $x
}

# ======================= R09 site twin: missing vs empty (class C) =======================
$r09 = $load + @'
function NetDoc([bool]$gw, [bool]$dns, [string]$dnsVal = '') { '<IPAddress><addressingType>static</addressingType><ipAddress>10.0.0.20</ipAddress><subnetMask>255.255.255.0</subnetMask>' + $(if ($gw) { '<DefaultGateway><ipAddress>10.0.0.1</ipAddress></DefaultGateway>' } else { '' }) + $(if ($dns) { '<PrimaryDNS><ipAddress>' + $dnsVal + '</ipAddress></PrimaryDNS><SecondaryDNS><ipAddress>' + $dnsVal + '</ipAddress></SecondaryDNS>' } else { '' }) + '</IPAddress>' }
function Fs-Http {
  param($Ip, $Path, $Method = 'GET', $Body, $ContentType, $Cred, $Timeout, $OutFile, [switch]$Secret, [switch]$Tls)
  if ($Method -eq 'PUT') { $script:puts++; $script:netXml = $Body; return [pscustomobject]@{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
  if ($Path -eq '/ISAPI/System/Network/interfaces') { return [pscustomobject]@{ code = 200; body = '<NetworkInterfaceList><NetworkInterface><id>1</id></NetworkInterface></NetworkInterfaceList>' } }
  if ($Path -like '/cgi-bin/configManager.cgi?action=getConfig&name=Network*') { return [pscustomobject]@{ code = 200; body = $script:dhBody } }
  return [pscustomobject]@{ code = 200; body = $script:netXml }
}
# Codex reproduce.ps1 "site-missing-DNS"
Run 'nodns' {
  $script:puts = 0; $script:netXml = NetDoc $true $false
  $n = Get-FsNet '10.0.0.20' Hikvision $null
  $w = Set-FsNet '10.0.0.20' Hikvision $null $n '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '1.1.1.1'
  $why = Get-FsNetMismatch '10.0.0.20' Hikvision $null $n '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '1.1.1.1'
  [ordered]@{ writeOk = [bool]$w.ok; puts = $script:puts; dnsNode = ($script:netXml -match 'DNS'); why = [string]$why }
}
# verification alone: a device whose settings have no DNS at all never "reads back" a DNS that was asked for
Run 'verifyonly' {
  $script:netXml = NetDoc $true $false
  $why = Get-FsNetMismatch '10.0.0.20' Hikvision $null $null '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '1.1.1.1'
  [ordered]@{ why = [string]$why }
}
# Undo needs the old router / DNS: a reading without them is not a complete backup for a forward write
Run 'gaphik' { $script:netXml = NetDoc $false $false; $n = Get-FsNet '10.0.0.20' Hikvision $null; [ordered]@{ read = [bool]$n; gap = [string](Get-FsNetUndoGap $n) } }
Run 'gapdahua' {
  $script:dhBody = "table.Network.DefaultInterface=eth0`r`ntable.Network.eth0.IPAddress=10.0.0.21`r`ntable.Network.eth0.SubnetMask=255.255.255.0`r`ntable.Network.eth0.DefaultGateway=10.0.0.1`r`ntable.Network.eth0.DhcpEnable=false"
  $n = Get-FsNet '10.0.0.21' Dahua $null; [ordered]@{ read = [bool]$n; gap = [string](Get-FsNetUndoGap $n) }
}
# a router asked for on a document with no router node is not written (2.2.19 skipped it and reported success)
Run 'nogw' {
  $script:puts = 0; $script:netXml = NetDoc $false $true '8.8.8.8'
  $n = Get-FsNet '10.0.0.20' Hikvision $null
  $w = Set-FsNet '10.0.0.20' Hikvision $null $n '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '8.8.8.8'
  [ordered]@{ writeOk = [bool]$w.ok; puts = $script:puts }
}
# control: explicit empty DNS nodes are a real setting: written, read back, nothing missing for Undo
Run 'emptyok' {
  $script:puts = 0; $script:netXml = NetDoc $true $true ''
  $n = Get-FsNet '10.0.0.20' Hikvision $null
  $w = Set-FsNet '10.0.0.20' Hikvision $null $n '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '1.1.1.1'
  $why = Get-FsNetMismatch '10.0.0.20' Hikvision $null $n '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '1.1.1.1'
  [ordered]@{ writeOk = [bool]$w.ok; puts = $script:puts; why = [string]$why }
}
'JSON=' + (ConvertTo-Json -Compress -Depth 8 -InputObject $R)
'@
$o = Invoke-Driver 'r09' $r09; $j = Get-Json $o
if (-not $j) { Check $false 'R09 driver ran' $o } else {
  $x = P $j 'nodns'; Check ((P $x 'writeOk') -eq $false -and (P $x 'puts') -eq 0 -and (P $x 'why')) 'R09 Codex repro site-missing-DNS: DNS asked for on a document with no DNS fields is NOT written and NOT verified' $x
  $x = P $j 'verifyonly'; Check ([bool](P $x 'why')) 'R09 the read-back check flags a requested DNS that is missing from the answer (never skipped when both readings lack it)' $x
  $x = P $j 'gaphik'; Check ((P $x 'read') -and (P $x 'gap')) 'R09 Hikvision: a reading without router / DNS is not enough for Undo (Get-FsNetUndoGap names them)' $x
  $x = P $j 'gapdahua'; Check ((P $x 'read') -and (P $x 'gap')) 'R09 Dahua twin: a reading without DnsServers lines is not enough for Undo' $x
  $x = P $j 'nogw'; Check ((P $x 'writeOk') -eq $false -and (P $x 'puts') -eq 0) 'R09 twin: a router asked for on a document with no router field is NOT written' $x
  $x = P $j 'emptyok'; Check ((P $x 'writeOk') -eq $true -and (P $x 'puts') -eq 1 -and -not (P $x 'why')) 'R09 control: explicit empty DNS fields are written and read back' $x
}

# ======================= R12 site twin: 200 is not a login (class C) + R13 (class F) =======================
$r12 = $load + @'
$script:mode = 'html'; $script:mac = 'AA:BB:CC:00:00:01'; $script:pwReq = 0; $script:sent = New-Object System.Collections.ArrayList
function Fs-Http {
  param($Ip, $Path, $Method = 'GET', $Body, $ContentType, $Cred, $Timeout, $OutFile, [switch]$Secret, [switch]$Tls)
  if ($Cred) { $script:pwReq++ }
  switch ($script:mode) {
    'html' { return [pscustomobject]@{ code = 200; body = '<html>Login page</html>' } }
    'dhhtml' { return [pscustomobject]@{ code = 200; body = '<!DOCTYPE html><html><body><form>login</form></body></html>' } }
    'timeout' { return [pscustomobject]@{ code = 0; body = ''; err = 'timeout' } }
    'refused' { return [pscustomobject]@{ code = 0; body = ''; err = 'refused' } }
    'dev' { if ($Method -eq 'PUT') { return [pscustomobject]@{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }; return [pscustomobject]@{ code = 200; body = ('<DeviceInfo><model>DS-2CD</model><serialNumber>SER1</serialNumber><macAddress>' + $script:mac + '</macAddress></DeviceInfo>') } }
  }
}
$script:FsLoginLedger = ''
Run 'hikhtml' { $script:mode = 'html'; [ordered]@{ s = [string](Test-FsLoginOnce '10.0.0.30' 'Hikvision' 'Pw123456') } }
Run 'dhhtml' { $script:mode = 'dhhtml'; [ordered]@{ s = [string](Test-FsLoginOnce '10.0.0.31' 'Dahua' 'Pw123456') } }
Run 'putok' { $script:mode = 'html'; [ordered]@{ ok = [bool](Fs-HikOk ([pscustomobject]@{ code = 200; body = '<html>Login page</html>' })) } }
Run 'resolveother' { $script:mode = 'dev'; $script:mac = 'AA:BB:CC:00:00:99'; [ordered]@{ s = [string](Resolve-FsPwChange '10.0.0.32' 'Hikvision' 'NewPw123' 'OldPw123' 'AA:BB:CC:00:00:01' '') } }
Run 'resolvehtml' { $script:mode = 'html'; [ordered]@{ s = [string](Resolve-FsPwChange '10.0.0.33' 'Hikvision' 'NewPw123' 'OldPw123') } }
Run 'resolveok' { $script:mode = 'dev'; $script:mac = 'AA:BB:CC:00:00:01'; [ordered]@{ s = [string](Resolve-FsPwChange '10.0.0.34' 'Hikvision' 'NewPw123' 'OldPw123' 'AA:BB:CC:00:00:01' '') } }
# R13: the real Test-FsLogin with a lost answer (timeout) keeps the reserved try; a refused connection (never sent) gives it back
Run 'timeoutkept' {
  $script:FsLoginLedger = Join-Path $D 'login-timeout.json'; $script:FsLoginFails = @{}; $script:FsLoginHold = @{}; $script:mode = 'timeout'
  [void](Test-FsLogin '10.0.0.40' 'Hikvision' 'Wrong123'); $b = Get-FsLoginBudget '10.0.0.40'; [ordered]@{ fails = [int]$b.fails }
}
Run 'refusedback' {
  $script:FsLoginLedger = Join-Path $D 'login-refused.json'; $script:FsLoginFails = @{}; $script:FsLoginHold = @{}; $script:mode = 'refused'
  [void](Test-FsLogin '10.0.0.41' 'Hikvision' 'Wrong123'); $b = Get-FsLoginBudget '10.0.0.41'; [ordered]@{ fails = [int]$b.fails }
}
# R13 twin: waiting for a restarting device sends no password while it does not answer at all
Run 'waitnopw' {
  $script:FsLoginLedger = Join-Path $D 'login-wait.json'; $script:FsLoginFails = @{}; $script:FsLoginHold = @{}; $script:mode = 'timeout'; $script:pwReq = 0
  function Fs-Sleep([int]$s) { Start-Sleep -Milliseconds 50 }
  $up = Wait-FsDevice '10.0.0.42' 'Hikvision' 'Site1234' 1
  $b = Get-FsLoginBudget '10.0.0.42'; [ordered]@{ up = [bool]$up; pwRequests = $script:pwReq; fails = [int]$b.fails }
}
'JSON=' + (ConvertTo-Json -Compress -Depth 8 -InputObject $R)
'@
$o = Invoke-Driver 'r12' $r12; $j = Get-Json $o
if (-not $j) { Check $false 'R12/R13 driver ran' $o } else {
  $x = P $j 'hikhtml'; Check ((P $x 's') -ne 'ok') 'R12 site twin: HTTP 200 with a login page is NOT a Hikvision login (no DeviceInfo document)' $x
  $x = P $j 'dhhtml'; Check ((P $x 's') -ne 'ok') 'R12 site twin: HTTP 200 with an HTML page is NOT a Dahua login (no type= answer)' $x
  $x = P $j 'putok'; Check ((P $x 'ok') -eq $false) 'R12 twin (class C sweep): a write answered HTTP 200 with a login page is not accepted (Fs-HikOk)' $x
  $x = P $j 'resolveother'; Check ((P $x 's') -ne 'changed') 'R12 site twin: after a password write, the new password logging in on ANOTHER device (MAC) is not "changed"' $x
  $x = P $j 'resolvehtml'; Check ((P $x 's') -eq 'unknown') 'R12 site twin: lost-answer reconciliation on 200 login pages = unknown, not changed' $x
  $x = P $j 'resolveok'; Check ((P $x 's') -eq 'changed') 'R12 control: the saved device''s DeviceInfo with the new password = changed' $x
  $x = P $j 'timeoutkept'; Check ((P $x 'fails') -eq 1) 'R13 a login try whose answer was lost (timeout) STAYS counted' $x
  $x = P $j 'refusedback'; Check ((P $x 'fails') -eq 0) 'R13 control: a try refused at connect (the password never left this PC) is given back' $x
  $x = P $j 'waitnopw'; Check ((P $x 'pwRequests') -eq 0 -and (P $x 'fails') -eq 0 -and -not (P $x 'up')) 'R13 twin: waiting for a device that does not answer sends no password (no tries spent on a restart)' $x
}

# Codex reproduce-safety.ps1 "lost-login-answer" (Test-FsLoginOnce stood in to answer 'noanswer' six times)
$r13 = $load + @'
$script:FsLoginLedger = Join-Path $D 'ambiguous-login.json'
$script:attempts = 0
function Test-FsLoginOnce { param($ip, $brand, $pw) $script:attempts++; 'noanswer' }
1..6 | ForEach-Object { [void](Test-FsLogin '10.0.0.21' Hikvision 'Wrong123') }
$b = Get-FsLoginBudget '10.0.0.21'
$R['lost'] = [ordered]@{ attempts = $script:attempts; fails = [int]$b.fails; max = [int]$script:FsMaxLoginFails }
'JSON=' + (ConvertTo-Json -Compress -Depth 8 -InputObject $R)
'@
$o = Invoke-Driver 'r13' $r13; $j = Get-Json $o
if (-not $j) { Check $false 'R13 driver ran' $o } else {
  $x = P $j 'lost'; Check ((P $x 'attempts') -le (P $x 'max') -and (P $x 'fails') -eq (P $x 'attempts')) 'R13 Codex repro lost-login-answer: six lost answers send at most the limit and every one stays counted' $x
}

# code shape: the undo file writer reads its file back (it is pure .NET, no stand-in seam)
$dev = [IO.File]::ReadAllText((Join-Path $tk 'FixSiteDevices.ps1'))
$m = [regex]::Match($dev, '(?s)function Write-FsFileAtomic.*?\n}')
Check ($m.Success -and $m.Value -match 'ReadAllText\(\$path\)' -and $m.Value -match 'throw') 'class A sweep: Write-FsFileAtomic (the undo file) reads the file in place back and throws when it differs (code shape)'

$fsrc = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
Check ($fsrc -match '\$ljAside' -and $fsrc -match '\$scanOk = \$ljAside -and (\$fcRead\.ok -and )?\(Test-FsFreshScan') 'class D sweep: Find cameras'' old out\latest.json must be GONE before the finder runs, else no scan result is used (code shape)'
$cv = [IO.File]::ReadAllText((Join-Path $tk 'CamViews.ps1'))
$m = [regex]::Match($cv, '(?s)function Save-CvKey.*?\n}')
Check ($m.Success -and $m.Value -match 'ReadAllBytes\(\$kf\)' -and $m.Value -match 'does not read back') 'class A sweep: CamViews says "Upload key saved" only after the key file reads back as written (code shape)'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ('Test-Fix2220Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
