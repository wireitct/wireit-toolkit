<# Test-Fix2220Core.ps1 - WireIt Toolkit 2.2.20, Codex review of 2.2.19 (head ca8d5b3): the "core" findings and their twins.
   R03 (Restore Network reads Fix NVR's real record fields pc.alias / pc.guid; a saved ID with no current ID is a mismatch; a record
   that names no adapter matches none), R08 Restore Network twin (full schema + TYPE validation of Fix NVR's and Fix this site's
   records before any change; damaged = kept aside as .unreadable-<time>.json + no change), R16 (a result proves it is THIS run's by
   the run id it echoes; run folders / snapshots / the camera list must be new or changed since the start), R17 (Go back and the
   start-up finish need the EXACT expected version record), R19 (an update whose half-way record cannot be cleared is not
   "installed"; Go back / start-up twins), R20 (WifiWatch's task installer: stop on a failed registration, read the task back).
   Codex's own reproductions (reproduce-restore.ps1, reproduce-extra.ps1 "undo-version-mismatch", reproduce-update-journal.ps1,
   reproduce-diagnostics.ps1 "task-registration-error") are rebuilt here as checks marked "Codex repro". Checks marked "control"
   pass on old and new code; "(code shape)" checks read source text only. The relay (HikRelay.gs) twin is in appsscript/tests/hikrelay.test.js.
   Real production functions run in their own PowerShell process per group; only Windows commands (adapters, scheduled tasks) and
   selected file failures are stand-ins. FIX2220CORE_REPO = another checkout (e.g. 2.2.19 ca8d5b3) to prove these checks fail there.
   Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2220CORE_REPO) { $repo = $env:FIX2220CORE_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2220core-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, $more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = $(if ($more -is [string]) { $more } else { ConvertTo-Json -Compress -Depth 6 -InputObject $more }); Write-Host ('     ' + $m.Substring(0, [Math]::Min(1500, $m.Length))) } }
}
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code, [hashtable]$envs = @{}) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $old = @{}; foreach ($k in $envs.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$envs[$k]) }
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev; foreach ($k in $envs.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function P($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { return $o.$k }; return $null }
$head = @'
function P($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { return $o.$k }; return $null }
$ErrorActionPreference = 'Continue'
$R = [ordered]@{}
function Run([string]$name, [scriptblock]$sb) { try { $R[$name] = (& $sb) } catch { $R[$name] = [ordered]@{ error = ($_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber) } } }
'@
try {
  # =====================================================================================
  Write-Host 'R03 / R08 (Restore Network: the real Fix NVR record fields, fresh identity, full schema + type check before any change)'
  $rd = Join-Path $tmp 'rn'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $rnDrv = @'
$classicFull = '{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":true,"ifIndex":5,"alias":"OLD-Ethernet","guid":"guid-a","dhcp":true,"ip":"192.168.1.50","gw":"192.168.1.1"},"written":"2026-11-11T07:00:00"}'
function J([string]$n, [string]$text) { $f = Join-Path $D ($n + '.json'); [IO.File]::WriteAllText($f, $text); return $f }
function Journals([string]$classicText, [string]$siteText) {
  $cf = ''; if ($classicText) { $cf = J ('c' + [guid]::NewGuid().ToString('N').Substring(0, 6)) $classicText }
  Set-Variable -Name FixNvrState -Value $cf -Scope Script
  $sd = Join-Path $D ('s' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force -Path $sd | Out-Null
  $script:RnFixSiteState = Join-Path $sd 'fixsite-temp-ips.json'
  if ($siteText) { [IO.File]::WriteAllText($script:RnFixSiteState, $siteText) }
  return @(Get-RnJournals)
}
$codexJournal = '{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"ifIndex":5,"alias":"OLD-Ethernet","guid":"guid-a","dhcp":true,"coexistence_before":"disabled"}}'
$repl = [pscustomobject]@{ name = 'NEW-Ethernet'; guid = 'guid-b'; ifIndex = 5; disabled = $false }
$replSt = [pscustomobject]@{ dhcp = $false; coexist = 'disabled'; active = @([pscustomobject]@{ ip = '10.0.0.10'; prefix = 24; origin = 'Manual' }); persistent = @(); routes = @(); dnsStatic = $false; unread = @() }
Run 'codex_classic' { $js = Journals $codexJournal ''; $own = Get-RnOwnStatic $repl $replSt $js; $plan = @(Get-RnPlan $repl $replSt $js ([bool]$own)); [ordered]@{ readable = [bool]$js[0].readable; bad = [string]$js[0].bad; match = [bool](Test-RnJournalFor $js[0] $repl); own = [bool]$own; plan = (@($plan | ForEach-Object { $_.op }) -join ',') } }
Run 'full_classic' { $js = Journals $classicFull ''; $own = Get-RnOwnStatic $repl $replSt $js; $plan = @(Get-RnPlan $repl $replSt $js ([bool]$own)); [ordered]@{ readable = [bool]$js[0].readable; name = [string]$js[0].name; guid = [string]$js[0].guid; match = [bool](Test-RnJournalFor $js[0] $repl); own = [bool]$own; plan = (@($plan | ForEach-Object { $_.op }) -join ',') } }
Run 'full_classic_same' { $js = Journals $classicFull ''; [ordered]@{ match = [bool](Test-RnJournalFor $js[0] ([pscustomobject]@{ name = 'OLD-Ethernet'; guid = '{GUID-A}'; ifIndex = 5 })) } }
Run 'guid_now_missing' { $script:RnOps = { param($op, $a) if ($op -eq 'list') { [pscustomobject]@{ name = 'Ethernet'; guid = ''; ifIndex = 5 } } }; $x = Get-RnAdapterAgain ([pscustomobject]@{ name = 'Ethernet'; guid = 'guid-a'; ifIndex = 5 }); $script:RnOps = $null; [ordered]@{ accepted = [bool]$x } }
Run 'journal_guid_now_missing' { $js = Journals $classicFull ''; [ordered]@{ match = [bool](Test-RnJournalFor $js[0] ([pscustomobject]@{ name = 'OLD-Ethernet'; guid = ''; ifIndex = 5 })) } }
Run 'journal_no_identity' { [ordered]@{ match = [bool](Test-RnJournalFor ([pscustomobject]@{ ifIndex = 5; name = ''; guid = ''; readable = $true }) ([pscustomobject]@{ name = 'Ethernet'; guid = 'g'; ifIndex = 5 })) } }
Run 'name_changed_guid_same' { $script:RnOps = { param($op, $a) if ($op -eq 'list') { [pscustomobject]@{ name = 'Ethernet 2'; guid = 'guid-a'; ifIndex = 5 } } }; $x = Get-RnAdapterAgain ([pscustomobject]@{ name = 'Ethernet'; guid = 'guid-a'; ifIndex = 5 }); $script:RnOps = $null; [ordered]@{ accepted = [bool]$x } }
# R08 twin: damaged-but-valid-JSON records
$bads = [ordered]@{
  c_dhcp_string = @('{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":"false","ip":"10.0.0.10","gw":"10.0.0.1"}}', '')
  c_firewall_string = @('{"version":2,"temps":[],"pc":{"coexistence_before":"disabled","firewall_rule":"no","cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":true,"ip":"","gw":""}}', '')
  c_ifindex_text = @('{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":"five"}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":true,"ip":"","gw":""}}', '')
  c_bad_ip = @('{"version":2,"temps":[{"ip":"999.1.1.1","ifIndex":5}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":true,"ip":"","gw":""}}', '')
  c_coexist_unknown_word = @('{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"coexistence_before":"maybe","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":true,"ip":"","gw":""}}', '')
  c_no_identity = @('{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"","guid":"","dhcp":true,"ip":"","gw":""}}', '')
  c_other_adapter_temp = @('{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":7}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":true,"ip":"","gw":""}}', '')
  s_dhcp_string = @('', '{"version":2,"coexistChanged":false,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"before":{"ifIndex":5,"name":"Ethernet","guid":"g","dhcp":"false","coexist":"disabled","addrs":[{"ip":"10.0.0.10","prefix":24}],"gw":["10.0.0.1"]}}')
  s_prefix = @('', '{"version":2,"coexistChanged":false,"temps":[],"before":{"ifIndex":5,"name":"Ethernet","guid":"g","dhcp":false,"coexist":"disabled","addrs":[{"ip":"10.0.0.10","prefix":40}],"gw":["10.0.0.1"]}}')
  s_coexist = @('', '{"version":2,"coexistChanged":true,"temps":[],"before":{"ifIndex":5,"name":"Ethernet","guid":"g","dhcp":true,"coexist":"sometimes","addrs":[],"gw":[]}}')
  s_coexistchanged_string = @('', '{"version":2,"coexistChanged":"true","temps":[],"before":{"ifIndex":5,"name":"Ethernet","guid":"g","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]}}')
  s_temp_other_adapter = @('', '{"version":2,"coexistChanged":false,"temps":[{"ip":"192.168.99.253","ifIndex":9}],"before":{"ifIndex":5,"name":"Ethernet","guid":"g","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]}}')
  s_old_list = @('', '[{"ip":"192.168.99.253","ifIndex":5}]')
}
foreach ($k in $bads.Keys) { $v = $bads[$k]; Run ('bad_' + $k) { $js = @(Journals $v[0] $v[1]); [ordered]@{ readable = [bool]$js[0].readable; bad = [string]$js[0].bad; dhcpBefore = $js[0].dhcpBefore; ips = (@($js[0].ips) -join ',') } }.GetNewClosure() }
Run 'good_site' { $js = @(Journals '' '{"version":2,"coexistChanged":false,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"before":{"ifIndex":5,"name":"Ethernet","guid":"g","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]}}'); [ordered]@{ readable = [bool]$js[0].readable; bad = [string]$js[0].bad; name = $js[0].name; guid = $js[0].guid } }
# whole runs (Invoke-RestoreNetwork) against a stand-in adapter; o: classic, site, dhcp, manual, swapAfterWrite, quarantine, lockDir
function RnRun([string]$n, [hashtable]$o) {
  [void](Journals ([string]$o.classic) ([string]$o.site))
  if ($o.quarantine) { [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $script:RnFixSiteState) 'fixsite-temp-ips.unreadable-20261111-010101.json'), '{') }
  $script:RnLines.Clear(); $script:RnDone.Clear(); if (Get-Variable -Name RnNotes -Scope Script -ErrorAction SilentlyContinue) { $script:RnNotes = @() }
  $script:t = @{ o = $o; ops = New-Object System.Collections.ArrayList; dhcp = [bool]$o.dhcp }
  $script:RnOps = { param($op, $a)
    [void]$script:t.ops.Add($op)
    $wrote = @($script:t.ops | Where-Object { $_ -in @('dhcp', 'coexist', 'removeaddr', 'removeroute', 'dnsreset', 'enable') }).Count
    switch ($op) {
      'list' { $g = $(if ($script:t.o.guid) { [string]$script:t.o.guid } else { 'guid-a' }); if ($script:t.o.swapAfterWrite -and $wrote) { $g = 'another-adapter' }; return [pscustomobject]@{ name = $(if ($script:t.o.name) { [string]$script:t.o.name } else { 'OLD-Ethernet' }); ifIndex = 5; desc = 'Ethernet'; disabled = $false; connected = $true; wifi = $false; guid = $g } }
      'state' { $act = @([pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; origin = $(if ($script:t.dhcp) { 'Dhcp' } else { 'Manual' }) }); if ($script:t.o.manual) { $act += [pscustomobject]@{ ip = '192.168.99.253'; prefix = 24; origin = 'Manual' } }
                return [pscustomobject]([ordered]@{ dhcp = $script:t.dhcp; coexist = 'disabled'; active = $act; persistent = @(); routes = @(); dnsStatic = $false; dnsServers = @(); unread = @() }) }
      'dhcp' { $script:t.dhcp = $true; return $true }
      'removeaddr' { $script:t.o.manual = $false; return $true }
      'isadmin' { return $true }
      'task' { return 'none' }
      'online' { return [pscustomobject]@{ link = $true; ip = '192.168.1.105'; gw = '192.168.1.1'; gwPing = $true; dns = $true; http = $true; httpIf = 5 } }
      default { return $true }
    }
  }
  $jdir = Split-Path -Parent $script:RnFixSiteState; $cdir = $(if ($FixNvrState) { Split-Path -Parent $FixNvrState } else { '' })
  if ($o.lockDir -and $IsLinux) { chmod 555 $jdir }
  try { $code = @(Invoke-RestoreNetwork)[-1] } finally { if ($o.lockDir -and $IsLinux) { chmod 755 $jdir } }
  $files = @(Get-ChildItem -LiteralPath $jdir -File | ForEach-Object { $_.Name })
  if ($cdir) { $files += @(Get-ChildItem -LiteralPath $cdir -File | Where-Object { $_.Name -like ((Split-Path -Leaf $FixNvrState) -replace '\.json$', '') + '*' } | ForEach-Object { $_.Name }) }
  $script:RnOps = $null
  return [ordered]@{ code = $code; said = (@($script:RnLines) -join "`n"); files = ($files -join ','); writes = (@($script:t.ops | Where-Object { $_ -in @('dhcp', 'coexist', 'removeaddr', 'removeroute', 'dnsreset', 'enable', 'reconnect') }) -join ',') }
}
$goodSite = '{"version":2,"coexistChanged":false,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"before":{"ifIndex":5,"name":"OLD-Ethernet","guid":"guid-a","dhcp":true,"coexist":"disabled","addrs":[],"gw":[]}}'
Run 'run_damaged_classic' { RnRun 'a' @{ classic = $bads['c_dhcp_string'][0]; dhcp = $false; manual = $true } }
Run 'run_damaged_site' { RnRun 'b' @{ site = $bads['s_dhcp_string'][1]; dhcp = $false; manual = $true } }
Run 'run_codex_classic' { RnRun 'c' @{ classic = $codexJournal; dhcp = $false; manual = $true } }
Run 'run_quarantined' { RnRun 'd' @{ quarantine = $true; dhcp = $false; manual = $true } }
Run 'run_good' { RnRun 'e' @{ site = $goodSite; dhcp = $true; manual = $true } }
Run 'run_close_fails' { RnRun 'f' @{ site = $goodSite; dhcp = $true; manual = $true; lockDir = $true } }
Run 'run_legacy_site' { RnRun 'h' @{ site = '[{"ip":"192.168.99.253","ifIndex":5}]'; dhcp = $false; manual = $true } }
Run 'run_swap_after_write' { RnRun 'g' @{ site = $goodSite; dhcp = $false; manual = $false; swapAfterWrite = $true } }
'JSON=' + (ConvertTo-Json -Compress -Depth 6 -InputObject $R)
'@
  $o = Invoke-Driver 'rn' ($head + "`n`$D = " + (Q $rd) + "`n. " + (Q (Join-Path $tk 'RestoreNetwork.ps1')) + " -ToolkitDir " + (Q $rd) + " -ReceiptDir " + (Q (Join-Path $rd 'receipts')) + " -FixNvrState " + (Q (Join-Path $rd 'none.json')) + " -NoElevate -Auto -OnlineSeconds 0 -WaitSeconds 0`n" + $rnDrv)
  $j = Get-Json $o; if (-not $j) { Write-Host $o.Substring([Math]::Max(0, $o.Length - 3000)) }
  $r = P $j 'codex_classic'
  Check ($r -and -not (P $r 'error') -and -not $r.match -and $r.own -and $r.plan -notmatch 'dhcp|removeaddr') 'R03 Codex repro "RN-classic-journal": a replacement adapter at the same number is NOT matched to the record, its own fixed address is recognised, no dhcp/removeaddr is planned (2.2.19: matched, dhcp,removeaddr)' $r
  Check ($r -and -not (P $r 'error') -and -not $r.readable -and $r.bad -match 'damaged') 'R08 twin: Codex''s record lacks fields Fix NVR always writes (firewall_rule, cleanup_task, ip, gw): it is damaged, nothing in it is used' $r
  $r = P $j 'full_classic'
  Check ($r -and -not (P $r 'error') -and $r.readable -and $r.name -eq 'OLD-Ethernet' -and $r.guid -eq 'guid-a') 'R03: Fix NVR''s real fields are read: pc.alias -> the adapter name, pc.guid -> the adapter ID (2.2.19: both empty)' $r
  Check ($r -and -not (P $r 'error') -and -not $r.match -and $r.own -and $r.plan -notmatch 'dhcp|removeaddr') 'R03: with a complete Fix NVR record the replacement adapter (other name + ID) is not matched and its own fixed setup is kept' $r
  $r = P $j 'full_classic_same'
  Check ($r -and -not (P $r 'error') -and $r.match) 'control: the adapter the record names (same number, name and ID; ID braces/case ignored) matches' $r
  $r = P $j 'guid_now_missing'
  Check ($r -and -not (P $r 'error') -and -not $r.accepted) 'R03 Codex repro "RN-known-guid-now-missing": an adapter whose ID was read but is now missing is NOT accepted as the same adapter (2.2.19: accepted by name)' $r
  $r = P $j 'journal_guid_now_missing'
  Check ($r -and -not (P $r 'error') -and -not $r.match) 'R03 twin: a record with a saved ID does not match an adapter whose current ID is missing (no fall-back to the name)' $r
  $r = P $j 'journal_no_identity'
  Check ($r -and -not (P $r 'error') -and -not $r.match) 'R03 twin: a record that names no adapter (no name, no ID) matches no adapter by its number alone' $r
  $r = P $j 'name_changed_guid_same'
  Check ($r -and -not (P $r 'error') -and -not $r.accepted) 'R03 twin (class B): an adapter found again with the same ID but another name is not taken as the same one (name AND ID as saved)' $r
  foreach ($k in @('c_dhcp_string', 'c_firewall_string', 'c_ifindex_text', 'c_bad_ip', 'c_coexist_unknown_word', 'c_no_identity', 'c_other_adapter_temp', 's_dhcp_string', 's_prefix', 's_coexist', 's_coexistchanged_string', 's_temp_other_adapter', 's_old_list')) {
    $r = P $j ('bad_' + $k)
    Check ($r -and -not (P $r 'error') -and -not $r.readable -and $r.bad -match 'damaged' -and -not $r.ips -and $null -eq $r.dhcpBefore) ('R08 twin (Restore Network, class E): damaged record ' + $k + ' is refused by schema/type check, nothing in it is used') $r
  }
  $r = P $j 'good_site'
  Check ($r -and -not (P $r 'error') -and $r.readable -and $r.name -eq 'Ethernet' -and $r.guid -eq 'g') 'control: a complete Fix this site record passes the check' $r
  $r = P $j 'run_damaged_classic'
  Check ($r -and -not (P $r 'error') -and [int]$r.code -eq 6 -and -not $r.writes -and $r.said -match 'NOT CHECKED' -and $r.files -match '\.unreadable-') 'R08 twin end-to-end: a Fix NVR record with "dhcp":"false" -> NO adapter change, FAILED (NOT CHECKED), the record kept aside as .unreadable- (2.2.19: changed the adapter)' $r
  $r = P $j 'run_damaged_site'
  Check ($r -and -not (P $r 'error') -and [int]$r.code -eq 6 -and -not $r.writes -and $r.files -match 'fixsite-temp-ips\.unreadable-') 'R08 twin end-to-end: a damaged Fix this site record -> no adapter change, kept aside (Fix this site''s own durable block reads it)' $r
  $r = P $j 'run_codex_classic'
  Check ($r -and -not (P $r 'error') -and [int]$r.code -eq 6 -and -not $r.writes) 'R03/R08 end-to-end: Codex''s classic record (missing fields) makes Restore Network change nothing' $r
  $r = P $j 'run_quarantined'
  Check ($r -and -not (P $r 'error') -and [int]$r.code -eq 6 -and -not $r.writes -and $r.said -match 'unreadable') 'R08 twin (owner decision "unreadable record = durable block"): a record Fix NVR / Fix this site already kept aside as unreadable blocks Restore Network too: no change' $r
  $r = P $j 'run_good'
  Check ($r -and -not (P $r 'error') -and [int]$r.code -eq 0 -and $r.said -match 'DONE' -and $r.files -match '\.restored-') 'control: a complete record for this adapter: its temporary address comes off, DONE, the record is closed (.restored-)' $r
  if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
    $r = P $j 'run_close_fails'
    Check ($r -and -not (P $r 'error') -and [int]$r.code -ne 0 -and $r.said -notmatch '(?m)^DONE' -and $r.said -match 'could not be marked done') 'class A twin (Restore Network): the record for this adapter could not be closed (rename refused) -> not DONE, said plainly (2.2.19: DONE with the record left)' $r
  } else { $script:deferred++; Write-Host 'DEFERRED class A twin: record close refused (needs chmod; Linux test box only)' }
  $r = P $j 'run_legacy_site'
  Check ($r -and -not (P $r 'error') -and [int]$r.code -eq 6 -and -not $r.writes -and $r.files -match '(^|,)fixsite-temp-ips\.json(,|$)' -and $r.files -notmatch 'unreadable') 'R08 twin: a well-formed 2.2.0 Fix this site record (no adapter named) -> no change, and it is LEFT in place for Fix this site (not kept aside as unreadable)' $r
  $r = P $j 'run_swap_after_write'
  Check ($r -and -not (P $r 'error') -and [int]$r.code -ne 0 -and $r.said -notmatch '(?m)^DONE' -and $r.said -match 'NOT CHECKED' -and $r.writes -notmatch 'reconnect') 'R03 twin (class B): the adapter''s ID changes after the DHCP write -> no reconnect, the read that would certify the result is refused: NOT CHECKED, not DONE (2.2.19: read the other adapter and said DONE)' $r

  # =====================================================================================
  Write-Host 'R16 (a result is THIS run''s only by the run id it echoes; run folders / snapshot / camera list new since the start)'
  $gd = Join-Path $tmp 'gui'; New-Item -ItemType Directory -Force -Path $gd | Out-Null
  $guiDrv = @'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $TK0 'WireItToolkit.ps1'), [ref]$null, [ref]$null)
$f = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-TkRunResult' }, $true)
. ([scriptblock]::Create($f.Extent.Text))
. (Join-Path $TK0 'ToolkitCore.ps1')
$res = Join-Path $D 'old-result.json'
Run 'codex_gui' { [IO.File]::WriteAllText($res, '{"ok":true,"msg":"OLD run successful"}'); $since = Get-Date; [IO.File]::SetLastWriteTime($res, $since.AddSeconds(-1)); $r = Read-TkRunResult $res $since; [ordered]@{ accepted = [bool]$r; msg = [string](P $r 'msg') } }
Run 'other_run_id' { [IO.File]::WriteAllText($res, '{"ok":true,"msg":"OLD","runId":"aaaa"}'); $since = (Get-Date).AddSeconds(-30); $r = Read-TkRunResult $res $since 'bbbb'; [ordered]@{ accepted = [bool]$r } }
Run 'this_run_id' { [IO.File]::WriteAllText($res, '{"ok":true,"msg":"NEW","runId":"bbbb"}'); $since = (Get-Date).AddSeconds(-30); $r = Read-TkRunResult $res $since 'bbbb'; [ordered]@{ accepted = [bool]$r; msg = [string](P $r 'msg') } }
Run 'save_run_result' { $env:WIREIT_RUN_ID = 'run-123'; $p = Join-Path $D 'saved.json'; Save-TkRunResult ([ordered]@{ ok = $true; msg = 'x' }) $p; $b = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; [ordered]@{ runId = [string]$b.runId } }
Run 'old_rundir' {
  $runs = Join-Path $D 'fixnvr/runs'; New-Item -ItemType Directory -Force -Path (Join-Path $runs 'Fix-20261111-070000') | Out-Null
  $before = Get-TkDirStamp $runs; $since = Get-Date
  $rd1 = Get-TkNewRunDir (Join-Path $D 'fixnvr') 'Fix' $since $before
  New-Item -ItemType Directory -Force -Path (Join-Path $runs 'Fix-20261111-070500') | Out-Null
  $d2 = Get-TkNewRunDir (Join-Path $D 'fixnvr') 'Fix' $since $before
  [ordered]@{ old = $(if ($rd1) { $rd1.Name } else { '' }); fresh = $(if ($d2) { $d2.Name } else { '' }) }
}
Run 'old_rundir_no_before' { $runs = Join-Path $D 'fixnvr2/runs'; $x = New-Item -ItemType Directory -Force -Path (Join-Path $runs 'Fix-20261111-070000'); $since = (Get-Date).AddSeconds(2); $rd2 = Get-TkNewRunDir (Join-Path $D 'fixnvr2') 'Fix' $since; [ordered]@{ old = $(if ($rd2) { $rd2.Name } else { '' }) } }
Run 'stale_scan' {
  $cr = Join-Path $D 'camreset'; New-Item -ItemType Directory -Force -Path (Join-Path $cr 'out') | Out-Null; $lj = Join-Path $cr 'out/latest.json'
  [IO.File]::WriteAllText($lj, '{"devices":[]}'); $start = [DateTime]::UtcNow; [IO.File]::SetLastWriteTimeUtc($lj, $start.AddMilliseconds(-500)); $stamp = Get-TkFileStamp $lj
  $a = Test-TkFreshScan $cr 0 $start $stamp
  [IO.File]::WriteAllText($lj, '{"devices":[{"IP":"10.0.0.5"}]}'); $b = Test-TkFreshScan $cr 0 $start $stamp
  [ordered]@{ stale = [bool]$a; fresh = [bool]$b }
}
Run 'stale_snapshot' {
  $sd = Join-Path $D 'fixnvr3/snapshots'; New-Item -ItemType Directory -Force -Path $sd | Out-Null; $sf = Join-Path $sd 'FixNVR snapshot 2026-11-11 0700.json'; [IO.File]::WriteAllText($sf, '{}')
  $before = Get-TkDirStamp $sd 'FixNVR snapshot*.json'; $since = (Get-Date).AddSeconds(-3)
  $s = Get-TkNewestSnapshot (Join-Path $D 'fixnvr3') $since $before
  [ordered]@{ old = $(if ($s) { $s.Name } else { '' }) }
}
'JSON=' + (ConvertTo-Json -Compress -Depth 6 -InputObject $R)
'@
  $o = Invoke-Driver 'gui' ($head + "`n`$D = " + (Q $gd) + "; `$TK0 = " + (Q $tk) + "`n" + $guiDrv)
  $j = Get-Json $o; if (-not $j) { Write-Host $o.Substring([Math]::Max(0, $o.Length - 3000)) }
  $r = P $j 'codex_gui'
  Check ($r -and -not (P $r 'error') -and -not $r.accepted) 'R16 Codex repro "GUI-previous-run-within-two-seconds": a previous run''s result (1 s before the start, no run id) is NOT accepted (2.2.19: "OLD run successful")' $r
  $r = P $j 'other_run_id'
  Check ($r -and -not (P $r 'error') -and -not $r.accepted) 'R16: a result written after the start but carrying ANOTHER run''s id is not accepted' $r
  $r = P $j 'this_run_id'
  Check ($r -and -not (P $r 'error') -and $r.accepted -and $r.msg -eq 'NEW') 'control: a result carrying this run''s id is accepted' $r
  $r = P $j 'save_run_result'
  Check ($r -and -not (P $r 'error') -and $r.runId -eq 'run-123') 'R16: Save-TkRunResult (ToolkitCore, used by ScanUpload / NvrCheck / FixIt) copies WIREIT_RUN_ID into the result and reads it back' $r
  $r = P $j 'old_rundir'
  Check ($r -and -not (P $r 'error') -and -not $r.old -and $r.fresh -eq 'Fix-20261111-070500') 'R16 twin (Get-TkNewRunDir): a Fix NVR run folder that was there before the start is never this run''s; the new one is' $r
  $r = P $j 'old_rundir_no_before'
  Check ($r -and -not (P $r 'error') -and -not $r.old) 'R16 twin: without a before-list only a folder made after the start counts (2.2.19: 3 s tolerance)' $r
  $r = P $j 'stale_scan'
  Check ($r -and -not (P $r 'error') -and -not $r.stale -and $r.fresh) 'R16 twin (Test-TkFreshScan): a camera list unchanged since the start (half a second old) is not this scan''s; a rewritten one is (2.2.19: 1 s tolerance)' $r
  $r = P $j 'stale_snapshot'
  Check ($r -and -not (P $r 'error') -and -not $r.old) 'R16 twin (Get-TkNewestSnapshot): a snapshot that was already there (within 5 s) is not this run''s' $r
  # ScanUpload end to end: the result file carries the run id the window gave it
  $su = Join-Path $tmp 'su'; New-Item -ItemType Directory -Force -Path (Join-Path $su 'Toolkit/logs'), (Join-Path $su 'CamReset/out') | Out-Null
  foreach ($x in @(Get-ChildItem -LiteralPath $tk -File)) { Copy-Item -LiteralPath $x.FullName -Destination (Join-Path $su 'Toolkit') }
  if (Test-Path -LiteralPath (Join-Path $tk 'modules')) { Copy-Item -LiteralPath (Join-Path $tk 'modules') -Destination (Join-Path $su 'Toolkit') -Recurse }
  [IO.File]::WriteAllText((Join-Path $su 'CamReset/out/latest.json'), '{"scannedAt":"2026-11-11T07:00:00","devices":[{"IP":"10.0.0.5","MAC":"AA:BB:CC:00:00:05","Model":"DS-2CD2143G2-I","Serial":"DS-2CD2143G2-I20230101AAWRK12345678"}]}')
  $null = Invoke-Driver 'su' ("& " + (Q (Join-Path $su 'Toolkit/ScanUpload.ps1')) + " -Site Review -CamResetDir " + (Q (Join-Path $su 'CamReset')) + " -ApiUrl http://127.0.0.1:9/none") @{ WIREIT_RUN_ID = 'su-run-77'; LOCALAPPDATA = (Join-Path $su 'lad'); APPDATA = (Join-Path $su 'ad') }
  $last = $null; try { $last = Get-Content -LiteralPath (Join-Path $su 'Toolkit/logs/scan-upload-last.json') -Raw | ConvertFrom-Json } catch {}
  Check ($last -and [string](P $last 'runId') -eq 'su-run-77') 'R16 end-to-end: ScanUpload''s scan-upload-last.json carries the run id it was started with (WIREIT_RUN_ID)' $(if ($last) { $last } else { 'no result file' })
  $gsrc = [IO.File]::ReadAllText((Join-Path $tk 'WireItToolkit.ps1'))
  $readers = @([regex]::Matches($gsrc, "Read-TkRunResult \(Join-Path \`$TK\.P\.Toolkit 'logs\\[a-z-]+\.json'\) \`$TK\.lastRunStarted \`$TK\.lastRunId")).Count
  Check ($gsrc -match '\$env:WIREIT_RUN_ID = \$TK\.run\.RunId' -and $readers -eq 4) ('R16 (code shape): every run sets WIREIT_RUN_ID, and all 4 result readers (scan upload, doctor, check site, fix) pass the run id (' + $readers + ' of 4)')
  $wl = 0; foreach ($pair in @(@('NvrCheck.ps1', "Save-TkRunResult ([pscustomobject]`$j) (Join-Path `$here 'logs\doctor-last.json')"), @('NvrCheck.ps1', "Save-TkRunResult `$chk (Join-Path `$here 'logs\check-site-last.json')"), @('FixIt.ps1', 'Save-TkRunResult ([pscustomobject]$out) $rp'), @('ScanUpload.ps1', 'Save-TkRunResult $keep $lastFile'))) { if ([IO.File]::ReadAllText((Join-Path $tk $pair[0])).Contains($pair[1])) { $wl++ } }
  Check ($wl -eq 4) ('R16 (code shape): the 4 result writers save through Save-TkRunResult (' + $wl + ' of 4)')

  # =====================================================================================
  Write-Host 'R17 / R19 (Go back and the start-up finish need the exact version record; an update is installed only when its half-way record is gone)'
  $ud = Join-Path $tmp 'upd'; New-Item -ItemType Directory -Force -Path $ud | Out-Null
  $updDrv = @'
. (Join-Path $TK0 'ToolkitCore.ps1')
function NewTk([string]$n) { $tk = Join-Path (Join-Path $D $n) 'Toolkit'; New-Item -ItemType Directory -Force -Path $tk | Out-Null; return $tk }
function UndoSetup([string]$n, [string]$prevVersion, [string]$undoFrom) {
  $tk = NewTk $n; $prev = Join-Path $tk 'previous/9.9.8'; New-Item -ItemType Directory -Force -Path $prev | Out-Null
  [IO.File]::WriteAllText((Join-Path $tk 'version.json'), '{"version":"9.9.9","previous":"9.9.8"}')
  if ($prevVersion) { [IO.File]::WriteAllText((Join-Path $prev 'version.json.prev'), '{"version":"' + $prevVersion + '"}') }
  [IO.File]::WriteAllText((Join-Path $prev 'undo.json'), '{"from":"' + $undoFrom + '","to":"9.9.9","added":[]}')
  New-Item -ItemType Directory -Force -Path (Join-Path $prev 'Toolkit') | Out-Null; [IO.File]::WriteAllText((Join-Path $prev 'Toolkit/tool.txt'), 'old 9.9.8 code'); [IO.File]::WriteAllText((Join-Path $tk 'tool.txt'), 'new 9.9.9 code')
  return $tk
}
function TkState([string]$tk) { [ordered]@{ version = [string](Read-TkJson (Join-Path $tk 'version.json')).version; tool = [IO.File]::ReadAllText((Join-Path $tk 'tool.txt')); journal = (Test-Path (Join-Path $tk 'previous/update-pending.json')) } }
Run 'codex_undo' { $tk = UndoSetup 'u1' '9.9.7' '9.9.8'; $ret = ''; $err = ''; try { $ret = Undo-TkUpdate $tk } catch { $err = $_.Exception.Message }; $s = TkState $tk; $s.ret = [string]$ret; $s.err = $err; $s }
Run 'undo_wrong_from' { $tk = UndoSetup 'u2' '9.9.8' '9.9.6'; $ret = ''; $err = ''; try { $ret = Undo-TkUpdate $tk } catch { $err = $_.Exception.Message }; $s = TkState $tk; $s.ret = [string]$ret; $s.err = $err; $s }
Run 'undo_ok' { $tk = UndoSetup 'u3' '9.9.8' '9.9.8'; $ret = ''; $err = ''; try { $ret = Undo-TkUpdate $tk } catch { $err = $_.Exception.Message }; $s = TkState $tk; $s.ret = [string]$ret; $s.err = $err; $s }
Run 'start_wrong_record' {
  $tk = UndoSetup 'u4' '9.9.7' '9.9.8'
  [IO.File]::WriteAllText((Join-Path $tk 'previous/update-pending.json'), ('{"prev":' + (ConvertTo-Json (Join-Path $tk 'previous/9.9.8')) + ',"from":"9.9.8","to":"9.9.9","added":[]}'))
  $msg = ''; $err = ''; try { $msg = Invoke-TkStartupRecovery $tk } catch { $err = $_.Exception.Message }; $s = TkState $tk; $s.msg = [string]$msg; $s.err = $err; $s
}
Run 'start_ok' {
  $tk = UndoSetup 'u5' '9.9.8' '9.9.8'
  [IO.File]::WriteAllText((Join-Path $tk 'previous/update-pending.json'), ('{"prev":' + (ConvertTo-Json (Join-Path $tk 'previous/9.9.8')) + ',"from":"9.9.8","to":"9.9.9","added":[]}'))
  $msg = ''; $err = ''; try { $msg = Invoke-TkStartupRecovery $tk } catch { $err = $_.Exception.Message }; $s = TkState $tk; $s.msg = [string]$msg; $s.err = $err; $s
}
function UpdSetup([string]$n) {
  $tk = NewTk $n; [IO.File]::WriteAllText((Join-Path $tk 'version.json'), '{"version":"9.9.8"}'); [IO.File]::WriteAllText((Join-Path $tk 'example.ps1'), 'OLD')
  $bytes = [Text.Encoding]::UTF8.GetBytes('NEW'); $h = [Security.Cryptography.SHA256]::Create(); $hash = ([BitConverter]::ToString($h.ComputeHash($bytes))).Replace('-', '').ToLower(); $h.Dispose()
  $m = [pscustomobject]@{ version = '9.9.9'; released = '2026-11-11'; commit = 'x'; base = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/x'; files = @([pscustomobject]@{ path = 'Toolkit/example.ps1'; sha256 = $hash }) }
  return @($tk, $m, $bytes)
}
function UpdState([string]$tk) { [ordered]@{ version = [string](Read-TkJson (Join-Path $tk 'version.json')).version; content = [IO.File]::ReadAllText((Join-Path $tk 'example.ps1')); journal = (Test-Path (Join-Path $tk 'previous/update-pending.json')) } }
Run 'upd_ok' { $x = UpdSetup 'p1'; $b = $x[2]; $err = ''; try { [void](Install-TkUpdate $x[1] $x[0] { param($url) , $b }) } catch { $err = $_.Exception.Message }; $s = UpdState $x[0]; $s.err = $err; $s }
Run 'codex_upd_journal' {
  $x = UpdSetup 'p2'; $b = $x[2]
  function Remove-Item { [CmdletBinding()]param([Parameter(Position = 0)]$Path, $LiteralPath, [switch]$Force, [switch]$Recurse) $p = $(if ($LiteralPath) { $LiteralPath } else { $Path }); if ($p -like '*update-pending.json') { Write-Error 'journal deletion denied'; return }; Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters }
  $ret = $null; $err = ''; try { $ret = Install-TkUpdate $x[1] $x[0] { param($url) , $b } } catch { $err = $_.Exception.Message }
  $s = UpdState $x[0]; $s.err = $err
  Remove-Item function:Remove-Item
  $msg = ''; $err2 = ''; try { $msg = Invoke-TkStartupRecovery $x[0] } catch { $err2 = $_.Exception.Message }
  $s.next = UpdState $x[0]; $s.nextMsg = [string]$msg; $s.nextErr = $err2; $s
}
Run 'undo_journal_stays' {
  $tk = UndoSetup 'u6' '9.9.8' '9.9.8'
  function Remove-Item { [CmdletBinding()]param([Parameter(Position = 0)]$Path, $LiteralPath, [switch]$Force, [switch]$Recurse) $p = $(if ($LiteralPath) { $LiteralPath } else { $Path }); if ($p -like '*update-pending.json') { return }; Microsoft.PowerShell.Management\Remove-Item -LiteralPath $p -Force -Recurse:$Recurse }
  $ret = ''; $err = ''; try { $ret = Undo-TkUpdate $tk } catch { $err = $_.Exception.Message }
  Remove-Item function:Remove-Item; $s = TkState $tk; $s.ret = [string]$ret; $s.err = $err; $s
}
Run 'start_journal_stays' {
  $tk = UndoSetup 'u7' '9.9.8' '9.9.8'
  [IO.File]::WriteAllText((Join-Path $tk 'previous/update-pending.json'), ('{"prev":' + (ConvertTo-Json (Join-Path $tk 'previous/9.9.8')) + ',"from":"9.9.8","to":"9.9.9","added":[]}'))
  function Remove-Item { [CmdletBinding()]param([Parameter(Position = 0)]$Path, $LiteralPath, [switch]$Force, [switch]$Recurse) $p = $(if ($LiteralPath) { $LiteralPath } else { $Path }); if ($p -like '*update-pending.json') { return }; Microsoft.PowerShell.Management\Remove-Item -LiteralPath $p -Force -Recurse:$Recurse }
  $msg = ''; $err = ''; try { $msg = Invoke-TkStartupRecovery $tk } catch { $err = $_.Exception.Message }
  Remove-Item function:Remove-Item; $s = TkState $tk; $s.msg = [string]$msg; $s.err = $err; $s
}
'JSON=' + (ConvertTo-Json -Compress -Depth 6 -InputObject $R)
'@
  $o = Invoke-Driver 'upd' ($head + "`n`$D = " + (Q $ud) + "; `$TK0 = " + (Q $tk) + "`n" + $updDrv)
  $j = Get-Json $o; if (-not $j) { Write-Host $o.Substring([Math]::Max(0, $o.Length - 3000)) }
  $r = P $j 'codex_undo'
  Check ($r -and -not (P $r 'error') -and $r.err -and -not $r.ret -and $r.version -eq '9.9.9' -and $r.tool -eq 'new 9.9.9 code' -and -not $r.journal) 'R17 Codex repro "undo-version-mismatch": a saved record saying 9.9.7 for the 9.9.8 copy -> Go back refused BEFORE any file changes; 9.9.9 stays (2.2.19: put back 9.9.8 files under a 9.9.7 record)' $r
  $r = P $j 'undo_wrong_from'
  Check ($r -and -not (P $r 'error') -and $r.err -and $r.version -eq '9.9.9' -and $r.tool -eq 'new 9.9.9 code') 'R17 twin: an undo record of another update (from 9.9.6) is refused, nothing changed' $r
  $r = P $j 'undo_ok'
  Check ($r -and -not (P $r 'error') -and -not $r.err -and $r.ret -eq '9.9.8' -and $r.version -eq '9.9.8' -and $r.tool -eq 'old 9.9.8 code' -and -not $r.journal) 'control: Go back with the exact saved record puts 9.9.8 back' $r
  $r = P $j 'start_wrong_record'
  Check ($r -and -not (P $r 'error') -and $r.err -and $r.journal -and $r.version -ne '9.9.7' -and $r.tool -eq 'new 9.9.9 code') 'R17 startup twin (ToolkitRecover): an interrupted update whose saved record is not the journal''s "from" keeps the journal (the block) and says so; the wrong record is not installed (2.2.19: installed 9.9.7, journal deleted)' $r
  $r = P $j 'start_ok'
  Check ($r -and -not (P $r 'error') -and -not $r.err -and $r.version -eq '9.9.8' -and $r.tool -eq 'old 9.9.8 code' -and -not $r.journal -and $r.msg -match '9\.9\.8') 'control: the start-up finish with the exact record puts 9.9.8 back and clears the journal' $r
  $r = P $j 'upd_ok'
  Check ($r -and -not (P $r 'error') -and -not $r.err -and $r.version -eq '9.9.9' -and $r.content -eq 'NEW' -and -not $r.journal) 'control: a normal update installs 9.9.9 and clears its half-way record' $r
  $r = P $j 'codex_upd_journal'
  Check ($r -and -not (P $r 'error') -and $r.err -match 'could not be installed' -and $r.version -eq '9.9.8' -and $r.content -eq 'OLD') 'R19 Codex repro (reproduce-update-journal.ps1): the half-way record cannot be removed -> the update is NOT reported installed; the old version is put back now (2.2.19: returned success with 9.9.9/NEW)' $r
  Check ($r -and -not (P $r 'error') -and $r.next -and $r.version -eq $r.next.version -and $r.content -eq $r.next.content -and $r.next.version -eq '9.9.8') 'R19: what this run leaves and what the next start leaves agree: version 9.9.8 / OLD (2.2.19: this run left 9.9.9/NEW, the next start went back to 9.9.8)' $r
  $r = P $j 'undo_journal_stays'
  Check ($r -and -not (P $r 'error') -and $r.err -and $r.err -match 'half-way record') 'R19 twin (Go back): a Go back whose half-way record stays is not reported as finished' $r
  $r = P $j 'start_journal_stays'
  Check ($r -and -not (P $r 'error') -and $r.err -and $r.err -match 'half-way record') 'R19 twin (start-up finish): a finish whose half-way record stays is not reported as finished' $r

  # =====================================================================================
  Write-Host 'R20 (WifiWatch task installer: stop on a failed registration, read the task back) + installer twins'
  $wd = Join-Path $tmp 'ww'; New-Item -ItemType Directory -Force -Path $wd | Out-Null
  $wwCopy = Join-Path $wd 'install-task.ps1'; Copy-Item -LiteralPath (Join-Path $repo 'wifiwatch/install-task.ps1') -Destination $wwCopy
  $stand = @'
function New-ScheduledTaskAction { param($Execute, $Argument) [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
function New-ScheduledTaskTrigger { param([switch]$AtStartup, [switch]$Once, $At, $RepetitionInterval) if ($AtStartup) { [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskBootTrigger' }; Repetition = $null } } else { [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; Repetition = [pscustomobject]@{ Interval = 'PT1M' } } } }
function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit, $MultipleInstances) [pscustomobject]@{ ExecutionTimeLimit = 'PT2M'; MultipleInstances = 'IgnoreNew'; Enabled = $true } }
$script:reg = $null
function Register-ScheduledTask { [CmdletBinding()]param($TaskName, $Description, $Action, $Trigger, $Settings, $User, $RunLevel, [switch]$Force)
  if ($MODE -eq 'deny') { Write-Error 'registration access denied'; return }
  $script:reg = [pscustomobject]@{ TaskName = $TaskName; Actions = @($Action); Triggers = @($Trigger); Settings = $Settings; Principal = [pscustomobject]@{ UserId = $User; RunLevel = $RunLevel } } }
function Get-ScheduledTask { [CmdletBinding()]param($TaskName) if (-not $script:reg) { Write-Error 'No MSFT_ScheduledTask objects found'; return }
  if ($MODE -eq 'norepeat') { $script:reg.Triggers = @($script:reg.Triggers | Where-Object { -not $_.Repetition }) }
  return $script:reg }
$out = @(); $err = ''
try { $out = @(. $WW) } catch { $err = $_.Exception.Message }
'JSON=' + (ConvertTo-Json -Compress -InputObject ([ordered]@{ out = ($out -join ' | '); err = $err }))
'@
  foreach ($mode in @('deny', 'norepeat', 'ok')) {
    $o = Invoke-Driver ('ww-' + $mode) ("`$MODE = '" + $mode + "'; `$WW = " + (Q $wwCopy) + "`n" + $stand)
    $r = Get-Json $o; if (-not $r) { $r = [pscustomobject]@{ out = $o; err = '' } }
    if ($mode -eq 'deny') { Check ($r.out -notmatch 'Installed' -and $r.err -match 'NOT INSTALLED') 'R20 Codex repro "task-registration-error": registration refused -> no "Installed" line; NOT INSTALLED with the reason (2.2.19: Installed)' $r }
    if ($mode -eq 'norepeat') { Check ($r.out -notmatch 'Installed' -and $r.err -match 'NOT INSTALLED' -and $r.err -match 'every minute') 'R20: Windows took the task but it reads back without the every-minute repeat -> NOT INSTALLED (the task is read back before success)' $r }
    if ($mode -eq 'ok') { Check ($r.out -match 'Installed' -and -not $r.err) 'control: a task that registers and reads back correctly -> Installed' $r }
  }
  $isrc = [IO.File]::ReadAllText((Join-Path $tk 'Install-Toolkit.ps1'))
  Check ($isrc -match 'Write-TkShortcutResult' -and $isrc -notmatch "\`$lnk\.Save\(\); 'Shortcut: '" -and $isrc -match 'Get-NetFirewallRule -DisplayName \$fwName') 'R20 twin (code shape, Install-Toolkit): a shortcut is reported only after it reads back, the firewall rule only after Get-NetFirewallRule finds it'
} finally {
  try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
Write-Host ('RESULT: Test-Fix2220Core: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 } else { exit 0 }
