<# Test-Fix2216Site.ps1 - WireIt Toolkit 2.2.16, Fix this site: Codex's 2.2.15 review findings F1, F3 and F4 (all P1).
   F1: a known recorder (.19) does not prove an UNREAD second NVR (.20) does not also record the camera. Every unread NVR on the site is
       an unresolved dependency of every camera: no password change, no move, no official reset (Still a problem, nonzero exit). The
       NOT CHECKED line no longer claims the cameras "kept their password and address". With a site list, an NVR channel with no video
       pointing at an address where nothing answers (e.g. a second NVR still on a moved camera's OLD address) is a problem, never
       "Nothing to fix".
   F3: NVR Undo (move and password, and every channel write) checks the NVR's own MAC / serial against the undo file BEFORE any write;
       the forward run records it. Another NVR, an unreadable identity, or an older undo file with none = nothing written, NOT moved
       back / NOT put back, nonzero exit (also on a second run).
   F4: Set-FsNvrChannel reads the channel root and the WHOLE addressing representation (ipAddress, hostName, ipv6Address,
       addressingFormatType) before any write: a hostname / IPv6 / odd-type / address-less channel, an answer that is not a channel or
       a failed read = no write, refused, reason given. Only a 404 (no channel) adds one.
   The real functions of FixSiteCore.ps1 / FixSiteDevices.ps1 in their own process (stand-ins for the HTTP layer only), and the real
   FixSite.ps1 against the repo's mock devices through the adapted reviewer reproductions (tests/repro-2.2.15, loopback only, each runs
   twice). Controls (marked "control") pass on old and new code. FIX2216_REPO = another checkout (e.g. 2.2.15 57c7fc9) to prove these
   tests fail there. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2216_REPO) { $repo = $env:FIX2216_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2216site-' + [guid]::NewGuid().ToString('N'))
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
  # F1: the planner, the guards, the reset selection, the problem lines (no devices)
  $d = Invoke-Driver 'f1' ($load + @'
$ErrorActionPreference = 'Continue'
function New-Obs([bool]$read20, $chs20) {
  [pscustomobject]@{
    pc = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; prefix = 24; mask = '255.255.255.0' }
    devices = @([pscustomobject]@{ kind = 'camera'; ip = '192.168.1.50'; mac = 'c4:2f:90:00:01:50'; brand = 'Hikvision'; model = 'DS-2CD'; serial = 'CAM50'; login = 'other password'; answers = $true; activated = $true; online = $true })
    nvrs = @([pscustomobject]@{ ip = '192.168.1.19'; brand = 'Hikvision'; login = 'site password'; channels = @([pscustomobject]@{ channel = 1; ip = '192.168.1.50'; online = $true; name = 'Gate' }); channelsRead = $true },
             [pscustomobject]@{ ip = '192.168.1.20'; brand = 'Hikvision'; login = 'site password'; channels = @($chs20); channelsRead = $read20 })
  }
}
$list = [pscustomobject]@{ scheme = '192.168.1'; cameras = @([pscustomobject]@{ name = 'Gate'; mac = 'c4:2f:90:00:01:50'; ip = '192.168.1.50'; nvr = '192.168.1.19'; channel = 1 }) }
$cred = @{ '192.168.1.19' = 'k'; '192.168.1.20' = 'k' }
$o = [ordered]@{}
$p = New-FsPlan $list (New-Obs $false @())
$c = @($p.cams | Where-Object { $_.mac -eq 'c4:2f:90:00:01:50' })[0]
$o.unknown = @($c.chUnknown)
$c.steps = @('backup', 'password', 'nvr', 'verify'); $c.state = 'fix'   # as -PasswordAll plans it: the password changes, its NVR channel follows
$o.pw = [string](Get-FsPwChangeBlock $c @(Get-FsCamRecorders $c) $cred)
$o.mv = [string](Get-FsMoveBlock $c)
$c.steps = @('backup', 'reset', 'nvr', 'verify'); $c.state = 'fix'
$r = Get-FsHikResetTargets $p $cred { param($ip) 'ok' }
$o.resetCams = @($r.targets | Where-Object { $_.kind -eq 'camera' }).Count; $o.resetWhy = @($r.blocked | ForEach-Object { [string]$_.why })
$o.manual = @(Get-FsManualLines $p)
# control: .20 read, nothing of this camera on it
$p2 = New-FsPlan $list (New-Obs $true @()); $c2 = @($p2.cams | Where-Object { $_.mac -eq 'c4:2f:90:00:01:50' })[0]
$o.plan2 = @(Format-FsPlan $p2)
$c2.steps = @('backup', 'password', 'nvr', 'verify'); $c2.state = 'fix'
$o.unknown2 = @($c2.chUnknown).Count; $o.pw2 = [string](Get-FsPwChangeBlock $c2 @(Get-FsCamRecorders $c2) $cred)
# orphan: .20 read, its ch 1 has no video and points at the camera's OLD address 192.168.0.150 (nothing answers there)
$p3 = New-FsPlan $list (New-Obs $true @([pscustomobject]@{ channel = 1; ip = '192.168.0.150'; online = $false; name = 'Gate backup' }))
$o.orphan = @($p3.missing | ForEach-Object { [string]$_.nvr + '|' + [string]$_.channel + '|' + (@($_.why) -join ';') })
$o.plan3 = @(Format-FsPlan $p3)
'JSON=' + ($o | ConvertTo-Json -Compress -Depth 6)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'F1 planner driver ran' $d }
  else {
    Check (@($j.unknown) -contains '192.168.1.20') 'F1 .19 read, .20 unread: .20 is an unresolved dependency of the camera (chUnknown)' (($j.unknown) -join ',')
    Check ($j.pw -match '192\.168\.1\.20' -and $j.pw -match 'not changed') 'F1 ...password change refused, naming .20' $j.pw
    Check ($j.mv -match '192\.168\.1\.20' -and $j.mv -match 'NOT moved') 'F1 ...address move refused, naming .20' $j.mv
    Check ([int]$j.resetCams -eq 0 -and @($j.resetWhy | Where-Object { $_ -match '192\.168\.1\.20' }).Count -eq 1) 'F1 ...the camera is NOT an official-reset target, blocked with the reason' ((@($j.resetWhy)) -join ' | ')
    Check (@($j.manual | Where-Object { $_ -match '192\.168\.1\.20' -and $_ -match 'NOT CHECKED' }).Count -eq 1) 'F1 ...NVR .20 is a NOT CHECKED problem line' ((@($j.manual)) -join ' | ')
    Check (-not @($j.manual | Where-Object { $_ -match 'kept their password and address' }).Count) 'F1 ...the problem line no longer claims cameras "kept their password and address"' ((@($j.manual)) -join ' | ')
    Check ([int]$j.unknown2 -eq 0 -and -not $j.pw2) 'F1 control: .20 read (nothing of this camera on it): no unresolved dependency, password change allowed' $j.pw2
    Check (@($j.orphan | Where-Object { $_ -like '192.168.1.20|1|*' -and $_ -match '192\.168\.0\.150' }).Count -eq 1) 'F1 orphan: .20 ch 1 with no video on the camera''s OLD address (nothing answers there) is a problem entry' ((@($j.orphan)) -join ' | ')
    Check (-not @($j.plan3 | Where-Object { $_ -match 'Nothing to fix' }).Count) 'F1 orphan: the plan never says "Nothing to fix"' ((@($j.plan3)) -join ' | ')
    Check (@($j.plan2 | Where-Object { $_ -match 'Nothing to fix' }).Count -eq 1) 'F1 control: no orphan channel, nothing wrong = "Nothing to fix" as before' ((@($j.plan2)) -join ' | ')
  }

  # =====================================================================================
  # F3: identity of the NVR before any Undo write
  $d = Invoke-Driver 'f3' ($load + @'
$ErrorActionPreference = 'Continue'
function Fs-LogLine { param($t) }
$script:Dev = @{ mac = 'C4-2F-90-00-00-18'; serial = 'NVR18' }
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>DS-7608</model>' + $(if ($script:Dev.serial) { '<serialNumber>' + $script:Dev.serial + '</serialNumber>' } else { '' }) + $(if ($script:Dev.mac) { '<macAddress>' + $script:Dev.mac + '</macAddress>' } else { '' }) + '</DeviceInfo>') } }
  return @{ code = 404; body = '' } }
$o = [ordered]@{}
$e = [pscustomobject]@{ ip = '192.168.1.18'; target = '192.168.1.19'; mac = 'c4:2f:90:00:00:18'; serial = 'NVR18' }
$o.same = [string](Get-FsUndoNvrBlock '192.168.1.19' $null $e)
$script:FsNvrIdOk = @{}; $script:Dev = @{ mac = 'c4:2f:90:00:00:20'; serial = 'OTHER-NVR' }
$o.other = [string](Get-FsUndoNvrBlock '192.168.1.19' $null $e)
$script:FsNvrIdOk = @{}; $script:Dev = @{ mac = ''; serial = '' }
$o.noid = [string](Get-FsUndoNvrBlock '192.168.1.19' $null $e)
$script:FsNvrIdOk = @{}; $script:Dev = @{ mac = 'c4:2f:90:00:00:18'; serial = 'NVR18' }
$o.oldfile = [string](Get-FsUndoNvrBlock '192.168.1.19' $null ([pscustomobject]@{ ip = '192.168.1.18'; target = '192.168.1.19' }))
$o.serialOnly = [string](Get-FsUndoNvrBlock '192.168.1.19' $null ([ordered]@{ nvr = '192.168.1.19'; nvr_mac = ''; nvr_serial = 'NVR18' }) 'nvr_mac' 'nvr_serial')
$script:FsNvrIds = @{}; $id = Get-FsNvrIdRecord '192.168.1.18' $null; $o.rec = [string]$id.mac + '|' + [string]$id.serial
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'F3 identity driver ran' $d }
  else {
    Check (-not $j.same) 'F3 control: the NVR at the address IS the one in the undo file (same MAC): allowed' $j.same
    Check ($j.other -match 'ANOTHER device') 'F3 another NVR (different MAC) at the address: refused' $j.other
    Check ($j.noid -match 'did not tell') 'F3 the NVR does not tell its MAC: refused' $j.noid
    Check ($j.oldfile -match 'older Toolkit|no MAC or serial') 'F3 an older undo file with no MAC / serial for the NVR stays unconfirmed (refused)' $j.oldfile
    Check (-not $j.serialOnly) 'F3 control: a camera-channel entry with only the NVR serial matches by serial' $j.serialOnly
    Check ($j.rec -eq 'c4:2f:90:00:00:18|NVR18') 'F3 the forward run reads the NVR''s MAC and serial for the undo file' $j.rec
  }
  $fsSrc = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
  Check ($fsSrc -match '\$rb\.nvrs \+= \[ordered\]@\{[^\r\n]*mac = \[string\]\$nid\.mac' -and $fsSrc -match '\$np = \[ordered\]@\{[^\r\n]*mac = \[string\]\$nid\.mac' -and $fsSrc -match 'nvr_mac = \[string\]\$nid\.mac') 'F3 (source): the NVR move, NVR password and camera-channel undo entries record the NVR''s MAC / serial'
  $mvBlk = [regex]::Match($fsSrc, '(?s)foreach \(\$n in @\(\$r0\.nvrs\)\) \{.*?Say \(''  NVR: back to ')
  Check ($mvBlk.Success -and $mvBlk.Value.IndexOf('Get-FsUndoNvrBlock ([string]$n.target)') -ge 0 -and $mvBlk.Value.IndexOf('Get-FsUndoNvrBlock ([string]$n.target)') -lt $mvBlk.Value.IndexOf('$w = Set-FsNet') -and $mvBlk.Value -match 'Get-FsUndoNvrBlock \(\[string\]\$n\.old\.ip\)') 'F3 (source): NVR move Undo checks identity before Set-FsNet, and at the original address before "the move never took"'
  $pwBlk = [regex]::Match($fsSrc, '(?s)foreach \(\$np in @\(\$r0\.nvr_passwords.*?old password back ')
  Check ($pwBlk.Success -and $pwBlk.Value.IndexOf('Get-FsUndoNvrBlock') -ge 0 -and $pwBlk.Value.IndexOf('Get-FsUndoNvrBlock') -lt $pwBlk.Value.IndexOf('Set-FsPassword')) 'F3 (source): NVR password Undo checks identity before Set-FsPassword'
  $chBlk = [regex]::Match($fsSrc, '(?s)# 2\.2\.1 \(review H8\): the NVR channel exactly as the backup has it.*?Say-PlainWarning \$nv')
  Check ($chBlk.Success -and $chBlk.Value.IndexOf('Get-FsUndoNvrBlock $nv') -ge 0 -and $chBlk.Value.IndexOf('Get-FsUndoNvrBlock $nv') -lt $chBlk.Value.IndexOf('Remove-FsNvrChannel')) 'F3 (source): camera-channel Undo checks the NVR''s identity before any channel write'

  # =====================================================================================
  # F4: Set-FsNvrChannel reads the whole addressing representation before writing
  $d = Invoke-Driver 'f4' ($load + @'
$ErrorActionPreference = 'Continue'
function Fs-LogLine { param($t) }
$script:W = 0; $script:Ch = ''; $script:ChCode = 200
$off = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>false</online></InputProxyChannelStatus></InputProxyChannelStatusList>'
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Method -eq 'PUT' -or $Method -eq 'POST') { $script:W++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
  if ($Path -like '*/status') { return @{ code = 200; body = $script:off } }
  return @{ code = $script:ChCode; body = $script:Ch } }
function Fs-HttpSecret { param($Ip, $Method, $Path, $Body, $Cred); return (Fs-Http -Ip $Ip -Method $Method -Path $Path -Body $Body -Cred $Cred) }
function T([string]$addr, [int]$code = 200, [string]$raw = '') {
  $script:W = 0; $script:ChCode = $code
  $script:Ch = $(if ($raw) { $raw } else { '<InputProxyChannel><id>1</id><sourceInputPortDescriptor>' + $addr + '<proxyProtocol>HIKVISION</proxyProtocol><managePortNo>8000</managePortNo><userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>' })
  $r = Set-FsNvrChannel '192.168.1.19' $null 1 '192.168.1.50' 'Sitepass123' 'Hikvision'
  return [ordered]@{ w = $script:W; action = [string]$r.action; why = [string]$r.why }
}
$o = [ordered]@{}
$o.host = T '<addressingFormatType>hostname</addressingFormatType><hostName>working-camera.local</hostName>'
$o.v6 = T '<addressingFormatType>ipaddress</addressingFormatType><ipv6Address>fe80::1</ipv6Address>'
$o.odd = T '<addressingFormatType>domain</addressingFormatType><ipAddress>192.168.1.77</ipAddress>'
$o.both = T '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>192.168.1.77</ipAddress><hostName>cam.local</hostName>'
$o.none = T '<addressingFormatType>ipaddress</addressingFormatType>'
$o.notch = T '' 200 '<ResponseStatus><statusCode>4</statusCode><ipAddress>192.168.1.77</ipAddress></ResponseStatus>'
$o.otherid = T '' 200 '<InputProxyChannel><id>2</id><sourceInputPortDescriptor><addressingFormatType>ipaddress</addressingFormatType><ipAddress>192.168.1.77</ipAddress></sourceInputPortDescriptor></InputProxyChannel>'
$o.e500 = T '' 500 'x'
$o.ipoff = T '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>192.168.1.77</ipAddress>'
$o.add404 = T '' 404 'x'
'JSON=' + ($o | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'F4 channel-writer driver ran' $d }
  else {
    foreach ($k in @(@('host', 'hostname-addressed channel (Codex''s case), status explicitly offline'), @('v6', 'IPv6-addressed channel'), @('odd', 'odd address type "domain" with an IP beside it'), @('both', 'an IP plus a hostName beside it'), @('none', 'a configured channel with no readable address'), @('notch', 'a 200 answer that is not a channel'), @('otherid', 'a 200 answer for ANOTHER channel id'), @('e500', 'the channel read failed (HTTP 500)'))) {
      $v = $j.($k[0]); Check ($v -and [int]$v.w -eq 0 -and $v.action -eq 'refused' -and $v.why) ('F4 ' + $k[1] + ': no PUT/POST, refused with a reason') ($(if ($v) { 'writes=' + $v.w + ' action=' + $v.action + ' why=' + $v.why } else { 'missing' }))
    }
    Check ($j.host.why -match 'working-camera\.local' -and $j.host.why -match 'NOT known') 'F4 ...the hostname case says how the channel is set up and that the camera is NOT known to be off' $j.host.why
    Check ([int]$j.ipoff.w -eq 1 -and $j.ipoff.action -eq 'updated') 'F4 control: an IP-addressed channel whose camera is explicitly offline is still updated'
    Check ([int]$j.add404.w -eq 1 -and $j.add404.action -eq 'added') 'F4 control: no channel there (404) = added'
  }

  # =====================================================================================
  # End to end: the real FixSite.ps1 against the mock devices (adapted reviewer reproductions, each runs twice)
  if (-not $py) { $script:deferred++; Write-Host 'DEFERRED end-to-end reproductions: no python on this PC (NEEDS PYTHON)' }
  else {
    $rp = Join-Path $PSScriptRoot 'repro-2.2.15'
    foreach ($s in @(@{ f = 'reproduce-unread-second-nvr.py'; n = 'F1 end to end: .19 known + .20 unread (first list read 500): no password change, no move, .20 keeps video, nonzero exit; orphaned old-address channel reported; control: one NVR changes, exit 0 (twice each)' },
                     @{ f = 'reproduce-undo-wrong-nvr.py'; n = 'F3 end to end: another NVR / no identity / older undo file at the moved-to address: nothing written, NOT moved back, nonzero exit (twice); control: same NVR goes back, exit 0' },
                     @{ f = 'reproduce-free-channel-unread.py'; n = 'control (passes on 2.2.15 too): unread channel list at the free-channel step: no channel written, NOT put on the NVR, nonzero exit (twice)' })) {
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $o = & $py (Join-Path $rp $s.f) --repo $repo --powershell $exe 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
      $m = [regex]::Match($o, '(?m)^(\d+) passed, (\d+) failed'); Check ($code -eq 0 -and $m.Success -and [int]$m.Groups[2].Value -eq 0) ($s.n + ' [' + $(if ($m.Success) { $m.Value } else { 'no summary' }) + ']') (@($o -split "`n" | Where-Object { $_ -match '^FAIL' }) -join "`n")
    }
  }
  foreach ($s in @(@{ f = 'reproduce-reset-second-unread.ps1'; n = 'F1 reproduction (planner + reset selector): .19 known, .20 unread: not a reset target, password/move refused, no "kept" claim' },
                   @{ f = 'reproduce-fixsite-hostname.ps1'; n = 'F4 reproduction: the 2.2.14 channel-guard cases with a hostname-addressed channel: no PUT in any of them; IP-offline and 404 controls still work' })) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $PSScriptRoot 'repro-2.2.15') $s.f) -Repo $repo 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $m = [regex]::Match($o, '(?m)^(\d+) passed, (\d+) failed'); Check ($code -eq 0 -and $m.Success -and [int]$m.Groups[2].Value -eq 0) ($s.n + ' [' + $(if ($m.Success) { $m.Value } else { 'no summary' }) + ']') (@($o -split "`n" | Where-Object { $_ -match '^FAIL' }) -join "`n")
  }
  # NEEDS WINDOWS CHECK: two real NVRs recording one camera with one channel list failing, real Hikvision NVR deviceInfo MAC/serial
  # formats for Undo, and real NVR channels addressed by hostname / IPv6, on Windows PowerShell 5.1 - DEFERRED, never PASS
  $script:deferred++; Write-Host 'DEFERRED real multi-NVR channel-list failures, real Hikvision NVR MAC/serial read-back for Undo and real hostname/IPv6-addressed NVR channels on Windows PowerShell 5.1 (NEEDS WINDOWS CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix2216Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
