<# Test-Fix2218Site.ps1 - WireIt Toolkit 2.2.18, Fix this site: Codex's review of 2.2.17 (head c3c0c69), findings 2, 3 and 5 (laptop side).
   F2 (P1) Undo of an NVR channel reads WHO is on the channel now before it deletes (a channel the run added) or puts back (a saved
      channel): another working camera on it now, or a channel that cannot be read = left alone, Undo incomplete, nonzero exit.
   F3 (P2) a network write (NVR or camera, forward or Undo) counts as fixed / back only when the device's whole network config, read back,
      has every field that was asked for (address, mask, router, DNS, fixed / DHCP); logging in at the address is not enough.
   F5 (P2) an unreadable record of this PC's network changes is kept as a marker ON DISK (fixsite-temp-ips.recovery-needed.json): a new
      start (a fresh PowerShell = a restarted tool) is still blocked and its clean-up never says "back to normal", until a verified
      recovery (this PC restarted since, and no temporary address on it) clears it.
   The real FixSite.ps1 (Undo = -Mode Rollback, and forward runs) against the repo's mock devices (tests/fix2218site, loopback only, each
   mode twice), and the real FixSiteCore.ps1 / FixSiteDevices.ps1 with stand-ins for Windows' network commands, each start in its own
   PowerShell process. Controls (marked "control") pass on old and new code. FIX2218SITE_REPO = another checkout (e.g. 2.2.17 c3c0c69)
   to prove these tests fail there. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2218SITE_REPO) { $repo = $env:FIX2218SITE_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2218site-' + [guid]::NewGuid().ToString('N'))
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
$load = ". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n"
try {
  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython
  foreach ($f in @('FixSite.ps1', 'FixSiteDevices.ps1', 'FixSiteCore.ps1')) { $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $tk $f), [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('control: parses: ' + $f) ($e | Out-String) }

  # =====================================================================================
  # F5: an unreadable record of this PC's network changes still blocks the NEXT start (each start = its own PowerShell process)
  $jdir = Join-Path $tmp 'journal'; New-Item -ItemType Directory -Force -Path $jdir | Out-Null
  $st = Join-Path $jdir 'fixsite-temp-ips.json'
  $jdrv = $load + '$StateFile = ' + (Q $st) + "`n" + @'
$ErrorActionPreference = 'Continue'
param()
'@ + "`n" + @'
$T18Phase = $env:FIX2218_PHASE; $T18Boot = $env:FIX2218_BOOT; $T18Skip = $env:FIX2218_SKIP   # names the code under test does not use (scriptblocks see the caller's variables)
function Fs-LogLine([string]$s) { }
$script:sim = @{ calls = New-Object System.Collections.ArrayList; addrs = New-Object System.Collections.ArrayList }
[void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; origin = 'Dhcp'; skip = $false })
$script:FsNetOps = @{
  state = { param($a) [pscustomobject]@{ dhcp = $true; coexist = 'disabled'; addrs = @($script:sim.addrs); gw = @('192.168.1.1') } }
  ident = { param($a) [pscustomobject]@{ name = 'Ethernet'; guid = '{6f1c2b9e-0d3a-4c55-9a51-2f0e5d7c1a11}' } }   # 2.2.19 (F05): which adapter is at that number
  allstate = { param($a) [pscustomobject]@{ adapters = @([pscustomobject]@{ name = 'Ethernet'; ifIndex = 5; state = (& $script:FsNetOps['state'] @{ ifIndex = 5 }) }) } }   # 2.2.19: every connected adapter, read completely
  coexist = { param($a) [void]$script:sim.calls.Add('coexist ' + $a.on); return $true }
  dhcp = { param($a) [void]$script:sim.calls.Add('dhcp ' + $a.on); return $true }
  addtemp = { param($a) [void]$script:sim.calls.Add('addtemp ' + $a.ip); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = 24; origin = 'Manual'; skip = $true }); return 'Preferred' }
  remove = { param($a) [void]$script:sim.calls.Add('remove ' + $a.ip); foreach ($x in @($script:sim.addrs | Where-Object { $_.ip -eq $a.ip })) { $script:sim.addrs.Remove($x) }; return $true }
  renew = { param($a) return $true }; wait = { param($a) return $true }; free = { param($a) return $true }
  boottime = { param($a) if ($T18Boot -eq 'after') { return [datetime]::UtcNow } elseif ($T18Boot -eq 'before') { return [datetime]::UtcNow.AddDays(-1) } else { return $null } }
  skipaddrs = { param($a) return [pscustomobject]@{ ips = @($(if ($T18Skip) { $T18Skip } else { @() })) } }
}
$script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $script:FsNetBlocked = $null
$pcA = [pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.1.1'; ifIndex = 5; dhcp = $true; name = 'Ethernet' }
if ($T18Phase -eq 'first') { Set-Content -LiteralPath $StateFile -Value '{"version":2,"before":{"ifIndex":5,"dhc' }
if ($T18Phase -eq 'legacy') { Set-Content -LiteralPath ($StateFile -replace '\.json$', '.unreadable-20261110-221500.json') -Value '{"version":2,"before":{"ifIndex":5,"dhc'; (Get-Item -LiteralPath ($StateFile -replace '\.json$', '.unreadable-20261110-221500.json')).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1) }
$lr = Clear-FsLeftoverTemps $StateFile
$t = ''; try { $t = Add-FsTempIp '192.168.0' $pcA $StateFile } catch { $t = 'threw: ' + $_.Exception.Message }
$rr = Remove-FsTempIps $StateFile
$files = @(Get-ChildItem -LiteralPath (Split-Path -Parent $StateFile) -File | ForEach-Object { $_.Name })
'JSON=' + ([ordered]@{ start = $(if ($lr) { [ordered]@{ ok = [bool]$lr.ok; problems = (@($lr.problems) -join ' | ') } } else { $null }); blocked = [string]$script:FsNetBlocked; added = [string]$t; addcalls = @($script:sim.calls | Where-Object { $_ -like 'addtemp*' }).Count; cleanupOk = [bool]$rr.ok; cleanup = (@($rr.problems) -join ' | '); files = $files } | ConvertTo-Json -Compress -Depth 5)
'@
  $jdrv = $jdrv.Replace("param()`n", '')
  function Invoke-Phase([string]$phase, [string]$boot, [string]$skip = '') {
    $env:FIX2218_PHASE = $phase; $env:FIX2218_BOOT = $boot; $env:FIX2218_SKIP = $skip
    try { $o = Invoke-Driver ('journal-' + $phase + '-' + $boot) $jdrv } finally { Remove-Item Env:FIX2218_PHASE, Env:FIX2218_BOOT, Env:FIX2218_SKIP -ErrorAction SilentlyContinue }
    $j = Get-Json $o; if (-not $j) { Write-Host $o }; return $j
  }
  $j1 = Invoke-Phase 'first' 'before'
  Check ($j1 -and $j1.start -and -not $j1.start.ok -and $j1.blocked -and $j1.addcalls -eq 0 -and -not $j1.cleanupOk) 'control: first start with an unreadable record: blocked, no temporary address added, clean-up NOT ok' ($j1 | ConvertTo-Json -Compress)
  $j2 = Invoke-Phase 'next' 'before'
  Check ($j2 -and $j2.start -and -not $j2.start.ok -and $j2.blocked) 'F5 a NEW start (fresh PowerShell, the PC not restarted): STILL blocked (2.2.17: no record found, nothing to do)' ($j2 | ConvertTo-Json -Compress)
  Check ($j2 -and $j2.addcalls -eq 0 -and -not $j2.added) 'F5 ...and no adapter change happens in that start (2.2.17 added a temporary address)' ($j2 | ConvertTo-Json -Compress)
  Check ($j2 -and -not $j2.cleanupOk -and $j2.cleanup -match 'restart') 'F5 ...and its clean-up never says ok while the problem stands, and says to restart the PC (2.2.17: ok=true)' ($j2 | ConvertTo-Json -Compress)
  Check ($j2 -and @($j2.files | Where-Object { $_ -eq 'fixsite-temp-ips.recovery-needed.json' }).Count -eq 1 -and @($j2.files | Where-Object { $_ -like 'fixsite-temp-ips.unreadable-*.json' }).Count -ge 1) 'F5 the marker fixsite-temp-ips.recovery-needed.json is on disk beside the kept unreadable record' (@($j2.files) -join ', ')
  $j3 = Invoke-Phase 'next' 'after' '192.168.0.253'
  Check ($j3 -and $j3.blocked -and $j3.addcalls -eq 0 -and $j3.blocked -match '192\.168\.0\.253') 'F5 the PC restarted but a temporary address is still on it: still blocked, the address named' ($j3 | ConvertTo-Json -Compress)
  $j3b = Invoke-Phase 'next' 'unknown'
  Check ($j3b -and $j3b.blocked -and $j3b.addcalls -eq 0) 'F5 when this PC last restarted cannot be read: still blocked (never cleared on a guess)' ($j3b | ConvertTo-Json -Compress)
  $j4 = Invoke-Phase 'next' 'after'
  Check ($j4 -and -not $j4.blocked -and $j4.addcalls -eq 1 -and $j4.cleanupOk) 'control: after a verified recovery (restarted since, no temporary address): not blocked, normal work again' ($j4 | ConvertTo-Json -Compress)
  Check ($j4 -and -not @($j4.files | Where-Object { $_ -eq 'fixsite-temp-ips.recovery-needed.json' -or $_ -like 'fixsite-temp-ips.unreadable-*.json' }).Count -and @($j4.files | Where-Object { $_ -like 'fixsite-temp-ips.recovery-cleared-*.json' }).Count -eq 1 -and @($j4.files | Where-Object { $_ -like 'fixsite-temp-ips.cleared-unreadable-*.json' }).Count -ge 1) 'F5 ...the marker and the unreadable record are kept, renamed as cleared (never deleted)' (@($j4.files) -join ', ')
  $j5 = Invoke-Phase 'next' 'before'
  Check ($j5 -and -not $j5.blocked -and $j5.addcalls -eq 1) 'control: the start after that stays clear' ($j5 | ConvertTo-Json -Compress)
  Remove-Item -LiteralPath $jdir -Recurse -Force; New-Item -ItemType Directory -Force -Path $jdir | Out-Null
  $j6 = Invoke-Phase 'legacy' 'before'
  Check ($j6 -and $j6.blocked -and $j6.addcalls -eq 0 -and -not $j6.cleanupOk) 'F5 an unreadable record an OLDER Toolkit kept (.unreadable-*.json, no marker): blocked too (2.2.17: forgotten)' ($j6 | ConvertTo-Json -Compress)

  # =====================================================================================
  # F3: the read-back comparison itself (Get-FsNetMismatch with a stand-in read)
  $d = Invoke-Driver 'netmis' ($load + @'
$ErrorActionPreference = 'Continue'
function Fs-LogLine { param($t) }
$script:Rd = $null
function Get-FsNet { param($ip, $brand, $cred) $script:FsNetWhy = 'the device answered HTTP 500'; return $script:Rd }
$o = [ordered]@{ have = [bool](Get-Command Get-FsNetMismatch -ErrorAction SilentlyContinue) }
if ($o.have) {
  $b = [pscustomobject]@{ ip = '192.168.1.19'; mask = '255.255.255.0'; gw = '192.168.1.254'; dhcp = $false; dns1 = '8.8.8.8'; dns2 = '' }
  $script:Rd = [pscustomobject]@{ ip = '192.168.1.19'; mask = '255.255.255.0'; gw = '192.168.1.1'; dhcp = $false; dns1 = '8.8.8.8'; dns2 = '' }; $o.match = Get-FsNetMismatch '192.168.1.19' 'Hikvision' $null $b '192.168.1.19' '255.255.255.0' '192.168.1.1' '8.8.8.8' '1.1.1.1'
  $script:Rd = [pscustomobject]@{ ip = '192.168.1.19'; mask = '255.255.0.0'; gw = '192.168.1.1'; dhcp = $false; dns1 = '4.4.4.4'; dns2 = '' }; $o.maskdns = Get-FsNetMismatch '192.168.1.19' 'Hikvision' $null $b '192.168.1.19' '255.255.255.0' '192.168.1.1' '8.8.8.8' '1.1.1.1'
  $script:Rd = [pscustomobject]@{ ip = '192.168.1.19'; mask = '255.255.255.0'; gw = '192.168.1.1'; dhcp = $true; dns1 = '8.8.8.8'; dns2 = '' }; $o.stilldhcp = Get-FsNetMismatch '192.168.1.19' 'Hikvision' $null $b '192.168.1.19' '255.255.255.0' '192.168.1.1' '8.8.8.8' '1.1.1.1'
  $script:Rd = [pscustomobject]@{ ip = '192.168.1.19'; mask = '255.255.255.0'; gw = '192.168.1.1'; dhcp = $false; dns1 = '8.8.8.8'; dns2 = '' }; $o.wantdhcp = Get-FsNetMismatch '192.168.1.19' 'Hikvision' $null $b '192.168.1.19' '' '' '' '' -Dhcp
  $script:Rd = $null; $o.unread = Get-FsNetMismatch '192.168.1.19' 'Hikvision' $null $b '192.168.1.19' '255.255.255.0' '192.168.1.1'
}
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  Check ($j -and $j.have) 'F3 a read-back comparison exists for network writes (Get-FsNetMismatch; 2.2.17 had none)' $d
  if (-not ($j -and $j.have)) { foreach ($n in @('every requested field reads back as asked', 'a wrong mask / DNS named', 'still on DHCP named', 'DHCP asked, fixed address named', 'unreadable settings NOT confirmed')) { Check $false ('F3 ' + $n + ' (no read-back comparison in this code)') } }
  else {
    Check (-not $j.match) 'F3 every requested field reads back as asked: no problem' ([string]$j.match)
    Check ($j.maskdns -match 'mask is 255\.255\.0\.0' -and $j.maskdns -match 'DNS 1 is 4\.4\.4\.4') 'F3 a wrong mask and a wrong DNS 1 are each named' ([string]$j.maskdns)
    Check ($j.stilldhcp -match 'still on DHCP') 'F3 a fixed address was asked for and the device is still on DHCP: named' ([string]$j.stilldhcp)
    Check ($j.wantdhcp -match 'DHCP is off') 'F3 DHCP was asked for (an Undo) and the device still has a fixed address: named' ([string]$j.wantdhcp)
    Check ($j.unread -match 'could not be read back') 'F3 settings that cannot be read back are NOT confirmed (never treated as a match)' ([string]$j.unread)
  }

  # =====================================================================================
  # F2 + F3 end to end: the real FixSite.ps1 against the mock devices (each mode runs twice)
  if (-not $py) { $script:deferred++; Write-Host 'DEFERRED end-to-end reproductions: no python on this PC (NEEDS PYTHON)' }
  else {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $py (Join-Path $PSScriptRoot 'fix2218site/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $lines = @($o -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL) ' })
    foreach ($l in $lines) { Check ($l -match '^PASS ') ('end to end: ' + ($l -replace '^(PASS|FAIL) ', '')) }
    $m = [regex]::Match($o, '(?m)^(\d+) passed, (\d+) failed')
    Check ($code -eq 0 -and $m.Success -and [int]$m.Groups[2].Value -eq 0 -and $lines.Count -eq 31) ('end to end: fix2218site/scenarios.py exits 0 with all 31 checks [' + $(if ($m.Success) { $m.Value } else { 'no summary' }) + ']') ($o.Substring([Math]::Max(0, $o.Length - 1500)))
  }
  $script:deferred++; Write-Host 'DEFERRED channel Undo on a real Hikvision NVR whose channel was re-used by another camera, and a real NVR / camera that acknowledges a network change it does not apply, on Windows PowerShell 5.1 (NEEDS WINDOWS / REAL-DEVICE CHECK)'
  $script:deferred++; Write-Host 'DEFERRED the recovery marker on a real Windows laptop: Get-CimInstance LastBootUpTime and Get-NetIPAddress SkipAsSource after a real restart, and after a real interrupted run (NEEDS WINDOWS CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix2218Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
