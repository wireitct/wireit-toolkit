<# Test-Fix2219Site.ps1 - WireIt Toolkit 2.2.19, Fix this site: Codex's review of 2.2.18 (head a7ceac8), the "site" findings and
   every twin of them in FixSite.ps1 / FixSiteCore.ps1 / FixSiteDevices.ps1.
   F01 channel Undo deletes / rewrites a channel only for a camera it has identified (logged in on its password AND its MAC at the
       channel's address); the "saved original address" path no longer skips identity.
   F02 Undo never moves a camera or an NVR onto an address another device answers on (or one it cannot check).
   F03 forward Fix this site reads the NVR's identity fresh before each write (no per-run cache): a recorder swapped after the scan
       is never written to; Undo's NVR identity is fresh too.
   F13 DHCP Undo is "back" only when the device is found again by its MAC, logs in, is the same device and reads back DHCP on;
       otherwise NOT CHECKED / NOT back, Undo incomplete.
   F19 a stream field that was asked for but the camera does not report (codec, SmartCodec, ...) is NOT CHECKED, never "already right",
       and nothing is written for it (forward and Undo).
   PoE: after a switch port power-cycle, "answers again" and the NVR channel write only for THIS camera (its MAC) and the NVR the scan
       found, read fresh.
   The real FixSite.ps1 against the repo's mock devices (tests/fix2219site/scenarios.py, loopback only, each mode twice), and the real
   FixSiteCore.ps1 / FixSiteDevices.ps1 with a stand-in for the device answers, each in its own PowerShell process. Controls (marked
   "control") pass on old and new code. FIX2219SITE_REPO = another checkout (e.g. 2.2.18 a7ceac8) to prove these tests fail there.
   Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2219SITE_REPO) { $repo = $env:FIX2219SITE_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2219site-' + [guid]::NewGuid().ToString('N'))
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
  foreach ($f in @('FixSite.ps1', 'FixSiteCore.ps1', 'FixSiteDevices.ps1', 'FixSiteBw.ps1', 'FixSiteWindow.ps1')) {
    $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $tk $f), [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + $f) ($e | Out-String)
  }

  # =====================================================================================
  # F19: a stream answer missing fields that were asked for (Codex's stream.ps1, adapted)
  $d = Invoke-Driver 'stream' ($load + @'
$ErrorActionPreference = 'Continue'
$script:Mode = 'gap'
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($script:Mode -eq 'err') { return @{ code = 401; body = '<userCheck><statusValue>401</statusValue></userCheck>' } }
  if ($Path -like '*capabilities' -and $script:Mode -eq 'nocap') { return @{ code = 200; body = '<StreamingChannel/>' } }   # Codex's repro: no Video element in the capabilities
  if ($Path -like '*capabilities') { return @{ code = 200; body = '<StreamingChannel><Video><videoResolutionWidth opt="1920"/><videoResolutionHeight opt="1080"/></Video></StreamingChannel>' } }
  if ($script:Mode -in @('gap', 'nocap')) { return @{ code = 200; body = '<StreamingChannel><id>101</id><Video><maxFrameRate>1500</maxFrameRate><videoResolutionWidth>1920</videoResolutionWidth><videoResolutionHeight>1080</videoResolutionHeight><constantBitRate>4096</constantBitRate><GovLength>15</GovLength></Video></StreamingChannel>' } }
  return @{ code = 200; body = '<StreamingChannel><id>101</id><Video><videoCodecType>H.264</videoCodecType><maxFrameRate>1500</maxFrameRate><videoResolutionWidth>1920</videoResolutionWidth><videoResolutionHeight>1080</videoResolutionHeight><constantBitRate>4096</constantBitRate><GovLength>15</GovLength><SmartCodec><enabled>false</enabled></SmartCodec></Video></StreamingChannel>' }
}
$want = [pscustomobject]@{ codec = 'H.264'; fps = 15; resolution = 'keep'; bitrate = 4096; gop = -1; smartCodec = 'off' }
$o = [ordered]@{}
foreach ($k in @('gap', 'nocap', 'full', 'err')) {
  $script:Mode = $k; $c = $null; $diff = @(); $txt = ''; $err = ''
  try { $c = Get-FsStream '10.0.0.21' 'Hikvision' $null; if ($c) { $diff = @(Get-FsSettingsDiff $c $want); $txt = [string](Format-FsSettingsDiff $diff) } } catch { $err = $_.Exception.Message }
  $o[$k] = [ordered]@{ read = ($null -ne $c); n = $diff.Count; unknown = @($diff | Where-Object { $_ -and $_.PSObject.Properties['unknown'] -and $_.unknown } | ForEach-Object { [string]$_.field }); text = $txt; err = $err }
}
'JSON=' + ($o | ConvertTo-Json -Compress -Depth 5)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'F19 stream driver ran' $d }
  else {
    Check ($j.gap.read -and $j.gap.n -gt 0) 'F19 the camera does not report its codec / SmartCodec: NOT "already right" (2.2.18: no difference at all)' ($d)
    Check (@($j.gap.unknown) -contains 'codec') 'F19 the missing codec comes back as unknown (the capabilities list no SmartCodec: none to switch off, that one is right)' ((@($j.gap.unknown)) -join ', ')
    Check ($j.nocap.read -and @($j.nocap.unknown) -contains 'codec' -and @($j.nocap.unknown).Count -ge 2) 'F19 Codex''s case: no SmartCodec in the answer AND capabilities that say nothing: codec and SmartCodec both unknown' ((@($j.nocap.unknown)) -join ', ')
    Check ($j.gap.text -match 'NOT CHECKED') 'F19 the words for the tech say NOT CHECKED' $j.gap.text
    Check ($j.full.read -and $j.full.n -eq 0) 'control: every asked-for field reported and right: nothing to change' ($d)
    Check (-not $j.err.read) 'F19 an error answer (HTTP 401) is not a stream reading (never read as all-empty = all right)' ($d)
  }

  # =====================================================================================
  # F03: the NVR's identity is read fresh on every check (Codex's site.ps1 "cached NVR identity", adapted)
  $d = Invoke-Driver 'nvrid' ($load + @'
$ErrorActionPreference = 'Continue'
$script:idNow = 'c4:2f:90:00:00:19'; $script:idReads = 0
function Get-FsIdentity { $script:idReads++; return [pscustomobject]@{ mac = $script:idNow; serial = $(if ($script:idNow -eq 'c4:2f:90:00:00:19') { 'NVR19' } else { 'ANOTHER' }); model = 'DS-7608' } }
$script:FsNvrIdOk = @{}; $script:FsNvrIds = @{}
$entry = [pscustomobject]@{ mac = 'c4:2f:90:00:00:19'; serial = 'NVR19' }
$o = [ordered]@{}
$o.first = [string](Get-FsUndoNvrBlock '192.168.1.19' $null $entry)
$r1 = Get-FsNvrIdRecord '192.168.1.19' $null
$script:idNow = 'c4:2f:90:00:00:99'
$o.second = [string](Get-FsUndoNvrBlock '192.168.1.19' $null $entry)
$r2 = Get-FsNvrIdRecord '192.168.1.19' $null
$o.rec1 = $(if ($r1) { [string]$r1.mac } else { '' }); $o.rec2 = $(if ($r2) { [string]$r2.mac } else { '' }); $o.reads = $script:idReads
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'F03 NVR identity driver ran' $d }
  else {
    Check (-not $j.first) 'control: the recorded NVR answers: no block' ([string]$j.first)
    Check ([bool]$j.second) 'F03 Undo: ANOTHER NVR answers on the same address in the same run: blocked (2.2.18 used the identity cached by the first check)' ([string]$j.second)
    Check ($j.rec1 -eq 'c4:2f:90:00:00:19' -and $j.rec2 -eq 'c4:2f:90:00:00:99') 'F03 forward: the NVR identity record is read fresh each time (2.2.18 kept the first answer for the whole run)' ('rec1=' + $j.rec1 + ' rec2=' + $j.rec2)
  }

  # =====================================================================================
  # class D: addressing modes are normalized (a string "false" / "manual" is a fixed address, an unknown mode is unknown)
  $d = Invoke-Driver 'dhcpmode' ($load + @'
$ErrorActionPreference = 'Continue'
$script:Dh = 'false'; $script:At = 'manual'
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Path -like '/cgi-bin/configManager.cgi*') { return @{ code = 200; body = ("table.Network.DefaultInterface=eth0`ntable.Network.eth0.IPAddress=192.168.1.22`ntable.Network.eth0.SubnetMask=255.255.255.0`ntable.Network.eth0.DefaultGateway=192.168.1.1`ntable.Network.eth0.DhcpEnable=" + $script:Dh + "`ntable.Network.eth0.DnsServers[0]=8.8.8.8`ntable.Network.eth0.DnsServers[1]=") } }
  if ($Path -eq '/ISAPI/System/Network/interfaces') { return @{ code = 200; body = '<NetworkInterfaceList><NetworkInterface><id>1</id></NetworkInterface></NetworkInterfaceList>' } }
  if ($Path -like '/ISAPI/System/Network/interfaces/1/ipAddress') { return @{ code = 200; body = ('<IPAddress><ipVersion>v4</ipVersion><addressingType>' + $script:At + '</addressingType><ipAddress>192.168.1.23</ipAddress><subnetMask>255.255.255.0</subnetMask><DefaultGateway><ipAddress>192.168.1.1</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>8.8.8.8</ipAddress></PrimaryDNS><SecondaryDNS><ipAddress></ipAddress></SecondaryDNS></IPAddress>') } }
  return @{ code = 404; body = '' }
}
$o = [ordered]@{}
foreach ($v in @('false', 'true')) { $script:Dh = $v; $n = Get-FsNet '192.168.1.22' 'Dahua' $null; $o['dh_' + $v] = $(if ($n) { $n.dhcp } else { 'noread' }) }
foreach ($v in @('manual', 'static', 'dynamic')) { $script:At = $v; $n = Get-FsNet '192.168.1.23' 'Hikvision' $null; $o['hik_' + $v] = $(if ($n) { $n.dhcp } else { 'noread' }) }
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'D addressing-mode driver ran' $d }
  else {
    Check ($j.dh_false -eq $false -and $j.dh_true -eq $true) 'D Dahua DhcpEnable=false / true read as fixed / DHCP' ($d)
    Check ($j.hik_manual -eq $false -and $j.hik_static -eq $false -and $j.hik_dynamic -eq $true) 'D Hikvision addressingType manual / static = fixed, dynamic = DHCP (2.2.18: only "dynamic" was compared)' ($d)
  }

  # =====================================================================================
  # source checks: the PoE path and the in-run password undo check identity (the e2e runs below exercise them)
  $fs = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
  $poe = [regex]::Match($fs, '(?s)\$back = \$false; if \(\$c\.listIp\).*?still missing - go check port').Value
  Check ($poe -match 'Get-FsUndoIdentityBlock \$c\.listIp' -and $poe -match 'Get-FsFwdNvrBlock') 'PoE: after the power-cycle, the camera''s MAC and the NVR (fresh, against the scan) are checked before "answers again" / the channel write' ''
  $ucp = [regex]::Match($fs, '(?s)function Undo-CamPassword.*?\n}').Value
  Check ($ucp -match 'Get-FsUndoIdentityBlock') 'in-run password undo: the camera''s MAC is checked before its old password is written back' ''

  # =====================================================================================
  # end to end: the real FixSite.ps1 against the mock devices (each mode runs twice)
  if (-not $py) { $script:deferred++; Write-Host 'DEFERRED end-to-end reproductions: no python on this PC (NEEDS PYTHON)' }
  else {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $py (Join-Path $PSScriptRoot 'fix2219site/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $lines = @($o -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL) ' })
    foreach ($l in $lines) { Check ($l -match '^PASS ') ('end to end: ' + ($l -replace '^(PASS|FAIL) ', '')) }
    $m = [regex]::Match($o, '(?m)^(\d+) passed, (\d+) failed')
    Check ($code -eq 0 -and $m.Success -and [int]$m.Groups[2].Value -eq 0 -and $lines.Count -eq 44) ('end to end: fix2219site/scenarios.py exits 0 with all 44 checks [' + $(if ($m.Success) { $m.Value } else { 'no summary' }) + ']') ($o.Substring([Math]::Max(0, $o.Length - 1500)))
  }
  $script:deferred++; Write-Host 'DEFERRED a real Hikvision NVR / camera on DHCP after Undo (found again by its MAC through Get-NetNeighbor on a real LAN), a real channel re-used by another camera, and a real switch power-cycle answered by another camera, on Windows PowerShell 5.1 (NEEDS WINDOWS / REAL-DEVICE CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix2219Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
