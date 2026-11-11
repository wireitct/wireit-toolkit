<# Test-Fix2220Cross.ps1 - WireIt Toolkit 2.2.20 (Nov 11 2026). CROSS-TOOL check for the class behind Codex 2.2.19 R03 (writer and
 reader of the same recovery record disagree on its field names / types): the record is written by the REAL writer (Fix NVR's
 Write-TempState; Fix this site's Add-FsTempIp -> Save-FsNetState) and read by the REAL reader (Restore Network's Get-RnJournals and
 Test-RnJournalFor), each in its own PowerShell. A record a tool writes must be accepted by Restore Network with its adapter identity
 (name AND InterfaceGuid) intact, must match that adapter, and must NOT match a replacement adapter at the same number.
 Only Windows adapter commands are stood in for. On 2.2.19 the classic record lost its identity (R03), so those checks fail there.
 FIX2220CROSS_REPO = another checkout to test (old-code proof). Exit code = failed checks. #>
$ErrorActionPreference = 'Stop'
$repo = $env:FIX2220CROSS_REPO; if (-not $repo) { $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2220cross-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') { if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace '\s+', ' ')) } } }
function Run-Child([string]$body, [string[]]$a) {
  $f = Join-Path $tmp ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
  [IO.File]::WriteAllText($f, $body, (New-Object Text.UTF8Encoding($false)))
  return (& $exe -NoProfile -ExecutionPolicy Bypass -File $f @a 2>&1 | Out-String)
}
$tk = Join-Path $tmp 'Toolkit'; $nvrState = Join-Path (Join-Path $tmp 'FixNVR') 'state'; $siteState = Join-Path (Join-Path (Join-Path $tk 'fixsite-runs') '_state') 'fixsite-temp-ips.json'
New-Item -ItemType Directory -Force -Path $tk, $nvrState, (Split-Path $siteState) | Out-Null
$classicFile = Join-Path $nvrState 'temp-ips.json'

# 1. Fix NVR writes its clean-up record with its real Write-TempState
$w1 = @'
param([string]$Fnv, [string]$File)
$ErrorActionPreference = 'Continue'
$ast = [Management.Automation.Language.Parser]::ParseFile($Fnv, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
function Log { param($s) }; function Say { param($s, $c) }; function Set-SafetyTask { }
$stateDir = Split-Path $File; $tempFile = $File
$script:temps = New-Object 'System.Collections.Generic.List[object]'
$script:pcChanges = [ordered]@{ coexistence_before = 'disabled'; firewall_rule = $false; cleanup_task = $false; ifIndex = 5; alias = 'Ethernet'; guid = '{6F1C2B9E-0D3A-4C55-9A51-2F0E5D7C1A11}'; dhcp = $false; ip = '10.0.0.10'; gw = '10.0.0.1' }
$script:temps.Add([pscustomobject]@{ ip = '192.168.99.253'; ifIndex = [uint32]5 })
$ok = Write-TempState
[Console]::Out.WriteLine('WROTE ' + [bool]$ok + ' ' + (Test-Path -LiteralPath $File))
'@
$o1 = Run-Child $w1 @('-Fnv', (Join-Path $repo 'FixNVR/FixNVR.ps1'), '-File', $classicFile)
Check ($o1 -match 'WROTE True True') 'Fix NVR''s real Write-TempState writes its clean-up record (setup for the cross checks)' $o1

# 2. Fix this site writes its PC network journal with the real Add-FsTempIp -> Save-FsNetState
$w2 = @'
param([string]$Repo, [string]$File)
$ErrorActionPreference = 'Continue'
. (Join-Path $Repo 'Toolkit/FixSiteCore.ps1'); . (Join-Path $Repo 'Toolkit/FixSiteDevices.ps1')
$script:FsNetOps = @{
  state = { [pscustomobject]@{ dhcp = $false; coexist = 'disabled'; addrs = @([pscustomobject]@{ ip = '10.0.0.10'; prefix = 24; skip = $false }); gw = @('10.0.0.1'); unread = @() } }
  ident = { [pscustomobject]@{ name = 'Ethernet'; guid = '{6F1C2B9E-0D3A-4C55-9A51-2F0E5D7C1A11}' } }
  free = { $true }
  addtemp = { 'Preferred' }
}
$a = Add-FsTempIp '192.168.99' ([pscustomobject]@{ ifIndex = 5; name = 'Ethernet' }) $File
[Console]::Out.WriteLine('WROTE ' + [string]$a + ' ' + (Test-Path -LiteralPath $File))
'@
$o2 = Run-Child $w2 @('-Repo', $repo, '-File', $siteState)
Check ($o2 -match 'WROTE 192\.168\.99\.\d+ True') 'Fix this site''s real Add-FsTempIp writes its PC network journal (setup for the cross checks)' $o2

# 3. Restore Network reads both with its real reader
$r = @'
param([string]$Repo, [string]$Tk, [string]$Nvr)
$ErrorActionPreference = 'Continue'
. (Join-Path $Repo 'Toolkit/RestoreNetwork.ps1') -ToolkitDir $Tk -FixNvrState $Nvr
$js = @(Get-RnJournals)
$same = [pscustomobject]@{ name = 'Ethernet'; guid = '{6F1C2B9E-0D3A-4C55-9A51-2F0E5D7C1A11}'; ifIndex = 5; disabled = $false }
$repl = [pscustomobject]@{ name = 'Ethernet'; guid = '{0000AAAA-0D3A-4C55-9A51-2F0E5D7C1A11}'; ifIndex = 5; disabled = $false }
foreach ($j in $js) {
  $kind = $(if ($j.file -like '*fixsite*') { 'site' } else { 'classic' })
  [Console]::Out.WriteLine(('J ' + $kind + ' readable=' + $j.readable + ' name=' + $j.name + ' guid=' + $j.guid + ' ifIndex=' + $j.ifIndex + ' same=' + [bool](Test-RnJournalFor $j $same) + ' repl=' + [bool](Test-RnJournalFor $j $repl) + ' still=' + (Test-Path -LiteralPath $j.file) + ' bad=' + $j.bad))
}
'@
$o3 = Run-Child $r @('-Repo', $repo, '-Tk', $tk, '-Nvr', $classicFile)
Write-Host ('  Restore Network read: ' + (($o3 -split "`n" | Where-Object { $_ -match '^J ' }) -join ' | '))
foreach ($kind in @('classic', 'site')) {
  $l = [string](@($o3 -split "`n" | Where-Object { $_ -match ('^J ' + $kind + ' ') }) | Select-Object -First 1)
  $who = $(if ($kind -eq 'classic') { 'Fix NVR' } else { 'Fix this site' })
  Check ($l -match 'readable=True' -and $l -match 'still=True') ('cross: Restore Network accepts the record ' + $who + ' really writes (not called damaged, not moved aside)') $l
  Check ($l -match 'name=Ethernet ' -and $l -match '(?i)guid=\{?6F1C2B9E-0D3A-4C55-9A51-2F0E5D7C1A11\}? ' -and $l -match 'ifIndex=5 ') ('cross: Restore Network keeps the adapter identity (name AND InterfaceGuid) from ' + $who + '''s record (R03 class)') $l
  Check ($l -match 'same=True') ('cross: that record matches the adapter it was written for (' + $who + ', control)') $l
  Check ($l -match 'repl=False') ('cross: that record does NOT match a replacement adapter at the same number with another InterfaceGuid (' + $who + ')') $l
}
Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Test-Fix2220Cross: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
exit $script:fail
