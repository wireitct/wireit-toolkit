<# Test-Fix2215Site.ps1 - WireIt Toolkit 2.2.15, Fix this site: Codex's 2.2.14 review findings R1, R2 and R3 (all P1).
   R1: an NVR channel list that could not be read is NOT "no channels". Read-FsNvrChannelList says whether it was read; the scan keeps
       channelsRead; the plan marks every camera that NVR may record (chUnknown) and the password guard, the move guard and the official
       reset selection refuse it (Still a problem, nonzero exit). The NVR itself is a NOT CHECKED problem line, never "Nothing to fix".
   R2: Undo matches the device's own MAC (or serial) with the undo file BEFORE any write; another device or one that does not tell =
       nothing written, NOT confirmed, nonzero exit, never "everything is back" (also on a second run).
   R3: Set-FsNvrChannel's guard overwrites another camera's channel only on an explicit <online>false</online> for that channel id in a
       valid status list; missing / empty / garbled / no entry / failed read = left alone and reported.
   The real functions of FixSiteCore.ps1 / FixSiteDevices.ps1 in their own process (stand-ins for the HTTP layer only), and the real
   FixSite.ps1 against the repo's mock devices through the adapted reviewer reproductions (tests/repro-2.2.14, loopback only, each runs
   twice). Controls (marked "control") pass on old and new code. FIX2215_REPO = another checkout (e.g. 2.2.14 f2850b4) to prove these
   tests fail there. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2215_REPO) { $repo = $env:FIX2215_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2215site-' + [guid]::NewGuid().ToString('N'))
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

  # =====================================================================================
  # R1: reading the channel list, the planner, the guards and the reset selection (no devices)
  $d = Invoke-Driver 'r1' ($load + @'
$ErrorActionPreference = 'Continue'
function Fs-LogLine { param($t) }
$script:Ans = @{ code = 200; body = '' }
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Path -like '*/status') { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
  return $script:Ans }
$o = [ordered]@{}
function Get-RdL($code, $body) { $script:Ans = @{ code = $code; body = $body }; try { $r = Read-FsNvrChannelList '192.168.1.19' $null; return [ordered]@{ ok = $r.ok; n = @($r.channels).Count; why = [string]$r.why } } catch { return [ordered]@{ ok = 'missing'; n = -1; why = $_.Exception.Message } } }
$two = '<InputProxyChannelList><InputProxyChannel><id>1</id><ipAddress>192.168.1.50</ipAddress></InputProxyChannel><InputProxyChannel><id>2</id><ipAddress>192.168.1.50</ipAddress></InputProxyChannel></InputProxyChannelList>'
$o.rd500 = Get-RdL 500 'temporary list failure'; $o.rdGarbled = Get-RdL 200 '<InputProxyChannelList><Input'; $o.rdOther = Get-RdL 200 '<ResponseStatus><statusCode>4</statusCode></ResponseStatus>'
$o.rdEmpty = Get-RdL 200 '<InputProxyChannelList/>'; $o.rdTwo = Get-RdL 200 $two
function New-Obs($read, $withList = $true) {
  $n = [ordered]@{ ip = '192.168.1.19'; brand = 'Hikvision'; login = 'site password'; channels = @() }
  if ($null -ne $read) { $n.channelsRead = $read }
  if ($read -eq $true) { $n.channels = @([pscustomobject]@{ channel = 1; ip = '192.168.1.50'; online = $false; name = 'Gate' }) }
  [pscustomobject]@{ pc = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; prefix = 24; mask = '255.255.255.0' }
    devices = @([pscustomobject]@{ kind = 'camera'; ip = '192.168.1.50'; mac = 'c4:2f:90:00:01:50'; brand = 'Hikvision'; model = 'DS-2CD'; serial = 'CAM50'; login = 'unknown'; answers = $true; activated = $true })
    nvrs = @([pscustomobject]$n) }
}
$list = [pscustomobject]@{ scheme = '192.168.1'; cameras = @([pscustomobject]@{ name = 'Gate'; mac = 'c4:2f:90:00:01:50'; ip = '192.168.1.50'; nvr = '192.168.1.19'; channel = 1 }) }
$cred = @{ '192.168.1.19' = 'known' }
function Sum($p) { $c = $p.cams[0]
  $rt = Get-FsHikResetTargets $p $cred { param($ip) 'ok' }
  return [ordered]@{ unknown = @(Get-FsProp $c 'chUnknown' @()); pw = [string](Get-FsPwChangeBlock $c @(Get-FsCamRecorders $c) $cred); mv = [string](Get-FsMoveBlock $c)
    targets = @($rt.targets | Where-Object { $_.kind -eq 'camera' }).Count; blocked = @($rt.blocked).Count; manual = @(Get-FsManualLines $p) } }
$o.unread = Sum (New-FsPlan $list (New-Obs $false))
$o.unreadNoList = Sum (New-FsPlan ([pscustomobject]@{ scheme = '192.168.1'; cameras = @() }) (New-Obs $false))
$o.read = Sum (New-FsPlan $list (New-Obs $true))
$o.legacy = Sum (New-FsPlan $list (New-Obs $null))
# a site where nothing else is wrong: the confirm screen must not say "Nothing to fix" while the NVR list is unread
$hl = [pscustomobject]@{ scheme = '192.168.1'; cameras = @() }
$ho = [pscustomobject]@{ pc = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; prefix = 24; mask = '255.255.255.0' }; devices = @(); nvrs = @([pscustomobject]@{ ip = '192.168.1.20'; brand = 'Hikvision'; login = 'site password'; channels = @(); channelsRead = $false }) }
$hp = New-FsPlan $hl $ho; $o.screen = (@(Format-FsPlan $hp) -join ' | '); $o.screenManual = @(Get-FsManualLines $hp).Count
'JSON=' + ($o | ConvertTo-Json -Depth 6 -Compress)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'R1 driver ran' $d } else {
    Check ($j.rd500.ok -eq $false -and $j.rd500.why -match '500') 'R1 Read-FsNvrChannelList: HTTP 500 = NOT read (with the reason), never "no channels"' ($j.rd500 | ConvertTo-Json -Compress)
    Check ($j.rdGarbled.ok -eq $false) 'R1 Read-FsNvrChannelList: a garbled answer = NOT read' ($j.rdGarbled | ConvertTo-Json -Compress)
    Check ($j.rdOther.ok -eq $false) 'R1 Read-FsNvrChannelList: an answer that is not a channel list = NOT read' ($j.rdOther | ConvertTo-Json -Compress)
    Check ($j.rdEmpty.ok -eq $true -and $j.rdEmpty.n -eq 0) 'R1 Read-FsNvrChannelList: a real empty list = read, 0 channels' ($j.rdEmpty | ConvertTo-Json -Compress)
    Check ($j.rdTwo.ok -eq $true -and $j.rdTwo.n -eq 2) 'R1 Read-FsNvrChannelList: a real list = read, both channels' ($j.rdTwo | ConvertTo-Json -Compress)
    Check (@($j.unread.unknown) -contains '192.168.1.19') 'R1 New-FsPlan: the camera the unread NVR records is marked (chUnknown)' ($j.unread | ConvertTo-Json -Compress)
    Check ($j.unread.pw -match 'password not changed' -and $j.unread.pw -match 'channel list') 'R1 password guard refuses while the NVR channel list is unknown' $j.unread.pw
    Check ($j.unread.mv -match 'NOT moved' -and $j.unread.mv -match 'channel list') 'R1 move guard refuses while the NVR channel list is unknown' $j.unread.mv
    Check ($j.unread.targets -eq 0 -and $j.unread.blocked -eq 1) 'R1 official reset: the camera is NOT a target, it is blocked with its reason' ($j.unread | ConvertTo-Json -Compress)
    Check (@($j.unread.manual | Where-Object { $_ -match 'NOT CHECKED' }).Count -eq 1) 'R1 the unread NVR is a NOT CHECKED problem line (counts as Still a problem)' (@($j.unread.manual) -join "`n")
    Check ($j.unreadNoList.pw -match 'channel list' -and $j.unreadNoList.mv -match 'channel list') 'R1 no site list: a camera with no known recorder may be on the unread NVR: refused too' ($j.unreadNoList | ConvertTo-Json -Compress)
    Check (-not ($j.screen -match 'Nothing to fix') -and $j.screen -match 'NOT everything was checked' -and $j.screenManual -ge 1) 'R1 an unread NVR with nothing else wrong: never "Nothing to fix", a problem line instead' $j.screen
    Check (-not $j.read.pw -and -not $j.read.mv -and $j.read.targets -eq 1) 'control: the list read, one channel: password, move and reset all allowed' ($j.read | ConvertTo-Json -Compress)
    Check (-not $j.legacy.pw -and -not $j.legacy.mv -and $j.legacy.targets -eq 1) 'control: an older scan record with no channelsRead field is treated as read (as before)' ($j.legacy | ConvertTo-Json -Compress)
  }

  # =====================================================================================
  # R3: the channel guard (no devices)
  $d = Invoke-Driver 'r3' ($load + @'
$ErrorActionPreference = 'Continue'
function Fs-LogLine { param($t) }
$script:St = @{ code = 200; body = '' }
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile) return $script:St }
$L = '<InputProxyChannelStatusList>'; $E = '</InputProxyChannelStatusList>'
$o = [ordered]@{}
function G($code, $body) { $script:St = @{ code = $code; body = $body }; return [string](Get-FsNvrChannelGuard '192.168.1.19' $null 1 '192.168.1.51' '192.168.1.50') }
$o.noflag = G 200 ($L + '<InputProxyChannelStatus><id>1</id></InputProxyChannelStatus>' + $E)
$o.empty = G 200 ($L + '<InputProxyChannelStatus><id>1</id><online/></InputProxyChannelStatus>' + $E)
$o.garbled = G 200 ($L + '<InputProxyChannelStatus><id>1</id><online>0</online></InputProxyChannelStatus>' + $E)
$o.noentry = G 200 ($L + '<InputProxyChannelStatus><id>3</id><online>false</online></InputProxyChannelStatus>' + $E)
$o.notlist = G 200 '<ResponseStatus><id>1</id><online>false</online></ResponseStatus>'
$o.http500 = G 500 ($L + '<InputProxyChannelStatus><id>1</id><online>false</online></InputProxyChannelStatus>' + $E)
$o.live = G 200 ($L + '<InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus>' + $E)
$o.off = G 200 ($L + '<InputProxyChannelStatus><id>1</id><online>false</online></InputProxyChannelStatus>' + $E)
$o.offUpper = G 200 ($L + '<InputProxyChannelStatus><id>1</id><online> FALSE </online></InputProxyChannelStatus>' + $E)
$o.own = [string](Get-FsNvrChannelGuard '192.168.1.19' $null 1 '192.168.1.50' '192.168.1.50')
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'R3 driver ran' $d } else {
    foreach ($k in @('noflag', 'empty', 'garbled', 'noentry', 'notlist', 'http500')) { Check ([string]$j.$k -match 'not overwritten') ('R3 channel showing another camera, status ' + $k + ': NOT overwritten, reported') ([string]$j.$k) }
    Check ([string]$j.live -match 'LIVE') 'control: another camera live (true): not overwritten' ([string]$j.live)
    Check (-not [string]$j.off -and -not [string]$j.offUpper) 'control: explicit false (also " FALSE "): the offline channel may be updated' ($j | ConvertTo-Json -Compress)
    Check (-not [string]$j.own) 'control: the channel already shows this camera: free to update' ([string]$j.own)
  }

  # =====================================================================================
  # R2: the Undo identity check (no devices)
  $d = Invoke-Driver 'r2' ($load + @'
$ErrorActionPreference = 'Continue'
$script:Hik = @{ code = 200; body = '' }; $script:Dh = @{}
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Path -like '/cgi-bin/*') { foreach ($k in $script:Dh.Keys) { if ($Path -like ('*' + $k + '*')) { return $script:Dh[$k] } }; return @{ code = 404; body = '' } }
  return $script:Hik }
function Hk($code, $mac, $ser) { $b = '<DeviceInfo xmlns="http://www.hikvision.com/ver20/XMLSchema"><model>DS-2CD</model>' + $(if ($ser) { '<serialNumber>' + $ser + '</serialNumber>' } else { '' }) + $(if ($mac) { '<macAddress>' + $mac + '</macAddress>' } else { '' }) + '</DeviceInfo>'; $script:Hik = @{ code = $code; body = $b } }
$o = [ordered]@{}
function B($brand, $mac, $ser) { try { return [string](Get-FsUndoIdentityBlock '192.168.1.50' $brand $null $mac $ser) } catch { return ('MISSING ' + $_.Exception.Message) } }
Hk 200 'C4-2F-90-00-01-50' 'CAM50'; $o.same = B 'Hikvision' 'c4:2f:90:00:01:50' ''
Hk 200 'c4:2f:90:00:01:51' 'OTHER-CAMERA'; $o.other = B 'Hikvision' 'c4:2f:90:00:01:50' ''
Hk 200 '' 'CAM50'; $o.nomac = B 'Hikvision' 'c4:2f:90:00:01:50' ''
Hk 401 'c4:2f:90:00:01:50' 'CAM50'; $o.refused = B 'Hikvision' 'c4:2f:90:00:01:50' ''
Hk 200 'c4:2f:90:00:01:50' 'CAM50'; $o.nojournal = B 'Hikvision' '' ''
Hk 200 '' 'cam50'; $o.serialOnly = B 'Hikvision' '' 'CAM50'
Hk 200 '' 'CAM51'; $o.serialOther = B 'Hikvision' '' 'CAM50'
$script:Dh = @{ 'name=Network' = @{ code = 200; body = "table.Network.DefaultInterface=eth0`r`ntable.Network.eth0.PhysicalAddress=3c:ef:8c:00:00:77`r`n" }; 'getSystemInfo' = @{ code = 200; body = "serialNumber=DH77`r`n" } }
$o.dhSame = B 'Dahua' '3c:ef:8c:00:00:77' ''; $o.dhOther = B 'Dahua' '3c:ef:8c:00:00:78' ''
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'R2 driver ran' $d } else {
    Check ($j.other -match 'ANOTHER device' -and $j.other -notmatch '^MISSING') 'R2 Undo identity: another camera (other MAC) at the address = refused with both MACs' $j.other
    Check ($j.nomac -match 'did not tell its MAC') 'R2 Undo identity: the device does not tell its MAC = refused (not certain)' $j.nomac
    Check ($j.refused -and $j.refused -notmatch '^MISSING') 'R2 Undo identity: device info not readable (HTTP 401) = refused' $j.refused
    Check ($j.nojournal -match 'no MAC or serial') 'R2 Undo identity: undo file without MAC or serial = refused' $j.nojournal
    Check ($j.serialOther -match 'ANOTHER device') 'R2 Undo identity: serial-only undo file, other serial = refused' $j.serialOther
    Check ($j.dhOther -match 'ANOTHER device') 'R2 Undo identity (Dahua): other PhysicalAddress = refused' $j.dhOther
    Check ($j.same -eq '' -and $j.serialOnly -eq '' -and $j.dhSame -eq '') 'R2 Undo identity: the same camera (MAC in any format; serial-only file; Dahua) = allowed' ($j | ConvertTo-Json -Compress)
  }
  # the Undo entrypoint checks identity BEFORE its first write (source order in the Rollback block)
  $src = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
  $rbStart = $src.IndexOf("if (`$Mode -eq 'Rollback')"); $idAt = $src.IndexOf('Get-FsUndoIdentityBlock', [Math]::Max(0, $rbStart))
  $firstWrite = $src.IndexOf('Set-FsStream $ip $c.brand $cr $cur $diff', [Math]::Max(0, $rbStart))
  Check ($rbStart -ge 0 -and $idAt -gt $rbStart -and $firstWrite -gt $idAt) 'R2 FixSite.ps1 Undo: the identity check comes before the first camera write (settings, password, address, channel)'

  # =====================================================================================
  # The real FixSite.ps1 against mock devices: the adapted reviewer reproductions, each mode twice
  if (-not $py) { $script:deferred++; Write-Host 'DEFERRED end-to-end FixSite runs (no Python on this PC to run the mock devices)' }
  else {
    $rp = Join-Path $PSScriptRoot 'repro-2.2.14'
    foreach ($s in @(@{ f = 'reproduce-multichannel-unread.py'; only = 'multi,multimove'; n = 'R1 end to end: one failed channel-list read: no password change, no move, both channels keep video, nonzero exit (twice)' },
                     @{ f = 'reproduce-undo-wrong-device.py'; only = 'wrongdev,samedev'; n = 'R2 end to end: another camera at the undo address: nothing written, NOT confirmed, nonzero exit (twice); control: same camera goes back, exit 0' })) {
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $o = & $py (Join-Path $rp $s.f) --repo $repo --powershell $exe --only $s.only 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
      $m = [regex]::Match($o, '(?m)^(\d+) passed, (\d+) failed'); Check ($code -eq 0 -and $m.Success -and [int]$m.Groups[2].Value -eq 0) ($s.n + ' [' + $(if ($m.Success) { $m.Value } else { 'no summary' }) + ']') (@($o -split "`n" | Where-Object { $_ -match '^FAIL' }) -join "`n")
    }
  }
  # NEEDS WINDOWS CHECK: real Hikvision / Dahua device-info MAC formats, a real NVR answering a channel-list read with an error and
  # real NVR status answers without an online flag, on Windows PowerShell 5.1 - DEFERRED, never PASS
  $script:deferred++; Write-Host 'DEFERRED real NVR channel-list failures, real status answers and real Hikvision/Dahua MAC read-back for Undo on Windows PowerShell 5.1 (NEEDS WINDOWS CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix2215Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
