<# Test-Fix2210.ps1 - behavioural tests for the 2.2.10 fixes (Codex's whole-repo review of 2.2.9 head 325f9ff, findings R01-R19).
   Each check reproduces the evidence Codex gave for its finding with the real functions and simulated operating-system / device
   calls (no real adapter, device or vault is touched). Windows PowerShell 5.1 or pwsh 7.
   Owner decision Nov 9 2026 (Moshe): R01, R08, R09 and the credential-storage part of R13 are not fixed (device passwords are only
   useful on the site network); this suite does not test them.
   NEEDS WINDOWS CHECK: the netsh / Get-NetIPAddress paths are stood in for here; run this suite on a Windows PC too. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$isWin = ($env:OS -eq 'Windows_NT')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2210-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Get-FnText([string]$file, [string[]]$only = @()) {
  $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  $fns = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
  $top = @($fns | Where-Object { $p = $_.Parent; $inFn = $false; while ($p) { if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { $inFn = $true; break }; $p = $p.Parent }; -not $inFn })
  if ($only.Count) { $top = @($top | Where-Object { $only -contains $_.Name }) }
  return (($top | ForEach-Object { $_.Extent.Text }) -join "`n")
}
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo $rel)) }
try {

  # =====================================================================================
  Write-Host 'R02. the second-IP steps keep DHCP on: coexistence first, a check after, a way back (NEEDS WINDOWS CHECK: netsh on a real DHCP adapter)'
  $o = Invoke-Driver 'r02' (". " + (Q (Join-Path $tk 'HikResetFlow.ps1')) + "`n" + @'
$cam = [pscustomobject]@{ serial = 'ECI-T44F220220903AAWRK52336660'; shortSerial = 'K52336660'; model = 'ECI-T44F2'; ip = '10.243.1.7'; mask = '255.255.255.0'; gw = '10.243.1.1' }
$nets = @([pscustomobject]@{ name = 'Ethernet'; ip = '192.168.1.127'; prefix = 24; wired = $true; count = 1 })
$sg = [pscustomobject]@{ ip = '10.243.1.50'; mask = '255.255.255.0'; prefix = 24 }
$a = @(Get-HikSubnetSteps $cam $nets $sg)
$script:said = New-Object System.Collections.ArrayList
$script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }
$script:HkLocalNets = @([pscustomobject]@{ name = 'Ethernet'; ip = '192.168.1.127'; prefix = 24; wired = $true; count = 1 }, [pscustomobject]@{ name = 'Ethernet'; ip = '10.243.1.50'; prefix = 24; wired = $true; count = 2 })
$script:HkSubnetCheckOff = $false; $script:SadpTest = $false
try { Show-HikExtraIpReminder $cam } catch {}
'JSON=' + (@{ steps = $a; after = @($script:said) } | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'R02 driver ran' $o }
  else {
    $s = @($j.steps) -join "`n"; $lines = @($j.steps)
    $iCo = -1; $iAdd = -1; $iShow = -1; $iChk = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($iShow -lt 0 -and $lines[$i] -match 'netsh interface ipv4 show (config|interface)') { $iShow = $i }
      if ($iCo -lt 0 -and $lines[$i] -match 'dhcpstaticipcoexistence=enabled') { $iCo = $i }
      if ($iAdd -lt 0 -and $lines[$i] -match 'netsh interface ipv4 add address') { $iAdd = $i }
      if ($iAdd -ge 0 -and $i -gt $iAdd -and $iChk -lt 0 -and $lines[$i] -match 'show config') { $iChk = $i }
    }
    Check ($s -notmatch '(?i)DHCP stays on') 'R02 the steps no longer promise "DHCP stays on" (2.2.9 said so without anything that keeps it on)' $s
    Check ($iShow -ge 0 -and $iShow -lt $iAdd) 'R02 the adapter is written down BEFORE the change (netsh ... show config / show interface: DHCP and coexistence as they are)' $s
    Check ($iCo -ge 0 -and $iCo -lt $iAdd) 'R02 DHCP/static coexistence is turned on BEFORE the address is added (without it Windows can switch DHCP off)' $s
    Check ($iChk -gt $iAdd -and $s -match '(?i)DHCP enabled.{0,20}Yes') 'R02 after the add, a check: show config must still say "DHCP enabled: Yes"' $s
    Check ($s -match 'netsh interface ipv4 set address name="Ethernet" source=dhcp') 'R02 a way back when DHCP was lost: netsh interface ipv4 set address name="Ethernet" source=dhcp' $s
    Check ($s -match 'netsh interface ipv4 delete address "Ethernet" 10\.243\.1\.50' -and $s -match 'dhcpstaticipcoexistence=disabled') 'R02 the remove steps take the address off AND put coexistence back as it was written down' $s
    $a2 = @($j.after) -join "`n"
    Check ($a2 -match 'dhcpstaticipcoexistence' -and $a2 -match '(?i)DHCP enabled.{0,20}Yes' -and $a2 -match 'source=dhcp') 'R02 the after-reset reminder says the same: remove, coexistence back, check DHCP, the way back' $a2
    $bad = @($lines | Where-Object { $_ -match '(?i)netsh[^\r\n]*(source=static|set address[^\r\n]*static)' })
    Check (-not $bad.Count) 'R02 no step switches the adapter to a fixed address' ($bad -join ' | ')
  }

  # =====================================================================================
  Write-Host 'R03. a temporary address whose removal failed stays in the journal until it is really gone (simulated adapter; NEEDS WINDOWS CHECK)'
  . (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
  $script:LogLines = New-Object System.Collections.ArrayList
  function Fs-LogLine([string]$s) { [void]$script:LogLines.Add($s) }
  $script:FsRestoreChecks = 1
  function New-SimNet {
    $script:sim = @{ dhcp = $true; coexist = 'disabled'; addrs = New-Object System.Collections.ArrayList; gw = @('192.168.1.1'); removeWorks = $false; addThrows = $true; calls = New-Object System.Collections.ArrayList; coexistThrows = $false; seenJournal = $null; journal = '' }
    [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; origin = 'Dhcp'; skip = $false })
    $script:FsNetOps = @{
      state = { param($a) [pscustomobject]@{ dhcp = $script:sim.dhcp; coexist = $script:sim.coexist; addrs = @($script:sim.addrs); gw = @($script:sim.gw) } }
      coexist = { param($a) [void]$script:sim.calls.Add('coexist ' + $a.on); if ($a.on -and $script:sim.journal -and (Test-Path -LiteralPath $script:sim.journal)) { $script:sim.seenJournal = (Get-Content -LiteralPath $script:sim.journal -Raw | ConvertFrom-Json) }
        $script:sim.coexist = $(if ($a.on) { 'enabled' } else { 'disabled' }); if ($a.on -and $script:sim.coexistThrows) { throw 'the run was stopped here' }; return $true }
      dhcp = { param($a) $script:sim.dhcp = [bool]$a.on; return $true }
      addtemp = { param($a) [void]$script:sim.calls.Add('addtemp ' + $a.ip); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = 24; origin = 'Manual'; skip = $true }); if ($script:sim.addThrows) { throw 'Get-NetIPAddress: the address state could not be read' }; return 'Preferred' }
      remove = { param($a) [void]$script:sim.calls.Add('remove ' + $a.ip); if ($script:sim.removeWorks) { foreach ($x in @($script:sim.addrs | Where-Object { $_.ip -eq $a.ip })) { $script:sim.addrs.Remove($x) } }; return $true }
      renew = { param($a) return $true }
      wait = { param($a) return $true }
      free = { param($a) return $true }
    }
    $script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $script:FsNetBlocked = $null
  }
  function Temps { return @($script:sim.addrs | Where-Object { $_.skip }) }
  $pcA = [pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.1.1'; ifIndex = 5; dhcp = $true; name = 'Ethernet' }
  $st3 = Join-Path $tmp 'r03/fixsite-temp-ips.json'; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $st3) | Out-Null
  New-SimNet; $script:sim.journal = $st3
  $t = Add-FsTempIp '192.168.0' $pcA $st3
  Check (@(Temps).Count -le 1) ('R03 Codex''s case (address added, the next read fails, the removal fails): no more addresses are piled on (on the adapter: ' + ((@(Temps) | ForEach-Object { $_.ip }) -join ',') + '; 2.2.9 left five)')
  Check (@($script:FsTemps | Where-Object { $_.ip -eq '192.168.0.253' }).Count -eq 1) 'R03 ...the address that may still be on the adapter stays in the journal (2.2.9 forgot it)'
  $sj = $null; try { $sj = Get-Content -LiteralPath $st3 -Raw | ConvertFrom-Json } catch {}
  Check ($sj -and @($sj.temps | Where-Object { $_.ip -eq '192.168.0.253' }).Count -eq 1) 'R03 ...and in the journal file on disk'
  $r = Remove-FsTempIps $st3
  Check (-not $r.ok -and (@($r.problems) -join ' ') -match '192\.168\.0\.253') 'R03 the restore checks it and does NOT say "back to normal" while the alias is still there' (@($r.problems) -join ' | ')
  Check (Test-Path -LiteralPath $st3) 'R03 ...and keeps the journal (2.2.9 erased it)'
  $script:sim.removeWorks = $true
  $r = Remove-FsTempIps $st3
  Check ($r.ok -and -not @(Temps).Count -and -not (Test-Path -LiteralPath $st3)) 'R03 once the removal works, the next restore takes it off, checks it and only then deletes the journal' (@($r.problems) -join ' | ')
  New-SimNet; $script:sim.journal = $st3; $script:sim.addThrows = $false; $script:sim.coexistThrows = $true; $script:sim.removeWorks = $true
  try { [void](Add-FsTempIp '192.168.0' $pcA $st3) } catch {}
  Check ($script:sim.seenJournal -and [bool]$script:sim.seenJournal.coexistChanged) 'R03 the journal already says "coexistence changed" when coexistence is switched on (2.2.9 wrote it after)'
  $script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $script:sim.coexistThrows = $false
  $r = Clear-FsLeftoverTemps $st3
  Check ($r -and $r.ok -and $script:sim.coexist -eq 'disabled') 'R03 ...so the next start puts coexistence back (it was off before)' ([string]($r | ConvertTo-Json -Compress))
  New-SimNet; $script:sim.addThrows = $false; $script:sim.removeWorks = $true
  Set-Content -LiteralPath $st3 -Value '{"version":2,"before":{"ifIndex":5,"dhc'
  $r = Clear-FsLeftoverTemps $st3
  $kept = @(Get-ChildItem -LiteralPath (Split-Path -Parent $st3) -Filter 'fixsite-temp-ips*' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'dhc' })
  Check ($r -and -not $r.ok) 'R03 an unreadable journal is a recovery problem, not "nothing to do"' ([string]($r | ConvertTo-Json -Compress))
  Check ($kept.Count -ge 1) 'R03 ...the unreadable journal is kept (not deleted) so the PC can still be put back by hand'
  $t = Add-FsTempIp '192.168.0' $pcA $st3
  Check (-not $t -and -not @($script:sim.calls | Where-Object { $_ -like 'addtemp*' }).Count) 'R03 ...and no temporary address is added while it is not sorted out'
  # Moshe's rule (Nov 9): a clean-up that cannot be verified ends with FAILED / "Run again", never with success words
  Check ((Get-FsExitWords 6) -match '^FAILED' -and (Get-FsExitWords 6) -match 'Run again') ('R03 the end words when this PC''s network is not back start with FAILED and say Run again (' + (Get-FsExitWords 6) + ')')
  $fsSrc = Read-Src 'Toolkit/FixSite.ps1'
  $snr = [regex]::Match($fsSrc, '(?s)function Say-NetRestore.*?\n\}').Value
  Check ($snr -match 'FAILED' -and $snr -match 'Run again') 'R03 ...and the red line on screen (and in the log) says FAILED and Run again' $snr
  $script:FsNetOps = $null; $script:FsNetBlocked = $null

  # =====================================================================================
  Write-Host 'R04. classic Fix NVR: no adapter change without a saved journal; failed clean-up keeps the journal (simulated Windows commands; NEEDS WINDOWS CHECK)'
  $fnv = Join-Path $repo 'FixNVR/FixNVR.ps1'
  $pre4 = (Get-FnText $fnv) + "`n" + '$ErrorActionPreference = ''Continue''; $Mock = $null; $stateDir = ' + (Q (Join-Path $tmp 'r04')) + '; New-Item -ItemType Directory -Force -Path $stateDir | Out-Null' + "`n" + '$logFile = Join-Path $stateDir ''log.txt''; $tempFile = Join-Path $stateDir ''temp-ips.json''' + "`n" + @'
$script:temps = New-Object System.Collections.Generic.List[object]
$script:pcChanges = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false }
$taskName = 'WireIt FixNVR cleanup'; $cfg = [pscustomobject]@{ temp_ip_hosts = @(253, 252, 247); safety_cleanup_minutes = 30 }
$script:sim = @{ addrs = New-Object System.Collections.ArrayList; removeWorks = $true; dhcp = 'Enabled'; coexist = 'disabled'; calls = New-Object System.Collections.ArrayList; task = $false }
function New-NetIPAddress { param($InterfaceIndex, $IPAddress, $PrefixLength, $SkipAsSource, $PolicyStore, $ErrorAction) [void]$script:sim.calls.Add('add ' + $IPAddress); [void]$script:sim.addrs.Add([pscustomobject]@{ IPAddress = $IPAddress; InterfaceIndex = $InterfaceIndex; SkipAsSource = $true; PolicyStore = 'ActiveStore'; AddressState = 'Preferred' }) }
function Remove-NetIPAddress { param($IPAddress, $InterfaceIndex, $PolicyStore, [switch]$Confirm, $ErrorAction) [void]$script:sim.calls.Add('remove ' + $IPAddress + '@' + $InterfaceIndex); if ($script:sim.removeWorks) { foreach ($x in @($script:sim.addrs | Where-Object { $_.IPAddress -eq $IPAddress -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) })) { $script:sim.addrs.Remove($x) } } }
function Get-NetIPAddress { param($InterfaceIndex, $IPAddress, $AddressFamily, $ErrorAction) return @($script:sim.addrs | Where-Object { (-not $IPAddress -or $_.IPAddress -eq $IPAddress) -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) }) }
function Get-NetIPInterface { param($InterfaceIndex, $AddressFamily, $ErrorAction) return [pscustomobject]@{ Dhcp = $script:sim.dhcp } }
function Set-NetIPInterface { param($InterfaceIndex, $AddressFamily, $Dhcp, $ErrorAction) [void]$script:sim.calls.Add('dhcp ' + $Dhcp); $script:sim.dhcp = $Dhcp }
function netsh { [void]$script:sim.calls.Add('netsh ' + ($args -join ' ')); if (($args -join ' ') -match 'coexistence=(\w+)') { $script:sim.coexist = $Matches[1] }; $global:LASTEXITCODE = 0; if (($args -join ' ') -match 'show interface') { return @('DHCP/Static IP coexistence     : ' + $script:sim.coexist) } }
function Register-ScheduledTask { $script:sim.task = $true }
function Unregister-ScheduledTask { [void]$script:sim.calls.Add('unregister'); $script:sim.task = $false }
function New-ScheduledTaskAction { 1 }; function New-ScheduledTaskTrigger { 1 }; function New-ScheduledTaskPrincipal { 1 }
function Remove-NetFirewallRule { }
function Start-Sleep { }
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; dhcp = $true; ip = '192.168.1.105'; prefix = 24 }
$script:pcNet = $pc
$out = [ordered]@{}
'@
  $o = Invoke-Driver 'r04a' ($pre4 + "`n" + @'
function Save-Json($obj, [string]$path) { throw 'disk full' }
$ip = Add-TempIp '192.168.0' $pc @()
$out.ip = [string]$ip; $out.calls = @($script:sim.calls); $out.addrs = @($script:sim.addrs | ForEach-Object { $_.IPAddress })
'JSON=' + ($out | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $o
  Check ($j -and -not $j.ip -and -not @($j.addrs).Count -and -not @($j.calls | Where-Object { $_ -match 'coexistence=enabled' }).Count) 'R04 the journal cannot be saved: Fix NVR adds no address and leaves coexistence alone (2.2.9 went on without a recovery record)' $o
  $o = Invoke-Driver 'r04b' ($pre4 + "`n" + @'
$ip = Add-TempIp '192.168.0' $pc @()
$out.ip = [string]$ip
$j0 = Get-Content -LiteralPath $tempFile -Raw | ConvertFrom-Json; $out.journalHasIf = [bool]($j0.pc.ifIndex -eq 5); $out.coexistSavedFirst = [bool]$j0.pc.coexistence_before
$script:sim.removeWorks = $false
$ok = Remove-AllTemp
$out.ok = [bool]$ok; $out.left = @($script:sim.addrs | ForEach-Object { $_.IPAddress }); $out.journal = (Test-Path -LiteralPath $tempFile); $out.tracked = @($script:temps | ForEach-Object { $_.ip })
$out.unregistered = (@($script:sim.calls) -contains 'unregister')
$script:temps.Clear(); $script:pcChanges.coexistence_before = $null
Invoke-LeftoverCleanup
$out.journal2 = (Test-Path -LiteralPath $tempFile); $out.unregistered2 = (@($script:sim.calls) -contains 'unregister')
$script:sim.removeWorks = $true; $script:sim.dhcp = 'Disabled'; $script:sim.calls.Clear()
Invoke-LeftoverCleanup
$out.removedOnIf = (@($script:sim.calls) -contains 'remove 192.168.0.253@5'); $out.left3 = @($script:sim.addrs | ForEach-Object { $_.IPAddress }); $out.journal3 = (Test-Path -LiteralPath $tempFile)
$out.dhcp3 = $script:sim.dhcp; $out.coexist3 = $script:sim.coexist; $out.calls3 = @($script:sim.calls)
'JSON=' + ($out | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'R04 driver ran' $o }
  else {
    Check ($j.ip -eq '192.168.0.253' -and $j.journalHasIf -and $j.coexistSavedFirst) 'R04 setup: a temporary address went on; the journal names the adapter (ifIndex) and the coexistence it had' $o
    Check (-not $j.ok -and @($j.left) -contains '192.168.0.253' -and @($j.tracked) -contains '192.168.0.253') 'R04 a removal that did nothing is reported as not back, and the address stays tracked (2.2.9 dropped it anyway)' $o
    Check ($j.journal -and -not $j.unregistered) 'R04 ...the journal and the safety clean-up task are kept (2.2.9 deleted both)' $o
    Check ($j.journal2 -and -not $j.unregistered2) 'R04 the start-up clean-up with the removal still failing keeps the journal and the task too' $o
    Check ($j.removedOnIf -and -not @($j.left3).Count -and -not $j.journal3) 'R04 once removal works, start-up clean-up takes it off on the SAVED adapter and only then deletes the journal' $o
    Check ($j.dhcp3 -eq 'Enabled' -and $j.coexist3 -eq 'disabled') 'R04 ...and puts DHCP and coexistence back from the saved before-state' $o
    Check ($o -match 'FAILED' -and $o -match 'Run again') 'R04 the failed clean-up says FAILED and Run again on screen (never silent)' $o
  }

} finally {
  try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
Write-Host ''
Write-Host ('Test-Fix2210: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
