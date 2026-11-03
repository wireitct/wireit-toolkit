<#
 FixSiteCore.ps1 - WireIt Toolkit 2.0 "Fix this site": the planner (no network, no screen, no passwords).
 Dot-sourced by FixSite.ps1 and by tests\Test-FixSite.ps1. Pure functions only: they read plain objects and return plain objects.

 WireIt IP standard (Nov 2 2026, Moshe): router hands out .100 and up, NVR .20 (.19/.18 if taken), cameras .21-.99,
 other WireIt gear .10-.19. PoE-port cameras on an NVR's own internal network (192.168.254.x) are never moved.

 The site list ("what SHOULD be here") is one JSON file in the site's Drive folder (Docs\WireIt site list.json):
   { site, siteId, scheme, saved, savedBy, nvrs:[{name, brand, model, serial, mac, ip}],
     cameras:[{name, brand, model, serial, mac, ip, channel, nvr, switch, port, settings:{codec,fps,resolution,bitrate}}] }
 No passwords are ever in it.
#>
$script:FsVersion = '2.0.0'
$script:FsPoeNets = @('192.168.254')

function Get-FsDefaults {
  [ordered]@{
    nvrHosts = @(20, 19, 18); camFirst = 21; camLast = 99; gearFirst = 10; gearLast = 19; routerFirst = 100; channelBase = 20
    moveOutOfBlock = $true          # a camera on the right scheme but outside .21-.99 (e.g. .150 in the router's range) is moved too
    passwordAll = $true             # every camera gets the site password, not only the ones we could not log in to
    maxPasswordTries = 3            # per camera per run, all known passwords together (cameras lock after 5-7 wrong tries)
    verifyHoldSec = 20              # video must stay up this long before the camera gets its check mark
    moveWaitSec = 120; rebootWaitSec = 180
    settings = [ordered]@{ codec = 'auto'; fps = 0; resolution = 'keep'; bitrate = 0; gopIsFps = $true; smartCodecOff = 'problem' }
  }
}

function Merge-FsOptions($opts) {
  $d = Get-FsDefaults
  if ($opts) {
    $props = $(if ($opts -is [Collections.IDictionary]) { @($opts.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $opts[$_] } }) } else { @($opts.PSObject.Properties) })
    foreach ($p in $props) {
      if ($p.Name -eq 'settings' -and $p.Value) {
        $sp = $(if ($p.Value -is [Collections.IDictionary]) { @($p.Value.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $p.Value[$_] } }) } else { @($p.Value.PSObject.Properties) })
        foreach ($q in $sp) { $d.settings[$q.Name] = $q.Value }
      } else { $d[$p.Name] = $p.Value }
    }
  }
  return $d
}

# ---------------- small helpers ----------------
function ConvertTo-FsMac([string]$m) {
  if (-not $m) { return '' }
  $h = ($m -replace '[^0-9A-Fa-f]', '').ToLower(); if ($h.Length -ne 12) { return '' }
  return (($h -split '(..)' | Where-Object { $_ }) -join ':')
}
function Get-FsP3([string]$ip) { if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return '' }; return (($ip -split '\.')[0..2] -join '.') }
function Get-FsLast([string]$ip) { if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return -1 }; return [int](($ip -split '\.')[3]) }
function Get-FsShort([string]$ip) { $l = Get-FsLast $ip; if ($l -lt 0) { return $ip }; return ('.' + $l) }
function Test-FsPoeNet([string]$ip) { return ($script:FsPoeNets -contains (Get-FsP3 $ip)) }
function Get-FsProp($o, [string]$name, $default = $null) {
  if ($null -eq $o) { return $default }
  if ($o -is [Collections.IDictionary]) { if ($o.Contains($name) -and $null -ne $o[$name]) { return $o[$name] }; return $default }
  $p = $o.PSObject.Properties[$name]; if ($p -and $null -ne $p.Value) { return $p.Value }; return $default
}
function Get-FsBrand([string]$brand, [string]$model = '', [string]$mac = '') {
  $b = ([string]$brand).Trim()
  if ($b -match '(?i)hik') { return 'Hikvision' }
  if ($b -match '(?i)dahua|amcrest|lorex') { return 'Dahua' }
  if ($b -match '(?i)uniview|unv') { return 'Uniview' }
  if ($model -match '^(?i)(DS-|IDS-|HNC|NC\d|LTS|iDS)') { return 'Hikvision' }
  if ($model -match '^(?i)(IPC-|DH-|N\d{2}[A-Z]{2}\d|NVR\d{2}|DHI-)') { return 'Dahua' }
  if ($b) { return $b }; return 'Unknown'
}
function Get-FsCamName($exp, $obs) {
  $n = [string](Get-FsProp $exp 'name' ''); if ($n) { return $n }
  $n = [string](Get-FsProp $obs 'name' ''); if ($n) { return $n }
  $ch = Get-FsProp $obs 'channel' $null; if (-not $ch) { $ch = Get-FsProp $exp 'channel' $null }
  if ($ch) { return ('Camera ch ' + $ch) }
  $ip = [string](Get-FsProp $obs 'ip' (Get-FsProp $exp 'ip' '')); if ($ip) { return ('Camera ' + $ip) }
  return 'Camera'
}

# ---------------- the site's scheme (what is "right") ----------------
function Get-FsScheme($observed, $expected) {
  # the router this PC is on is the truth: its first 3 numbers. Fallback: the site list's saved scheme.
  $pc = Get-FsProp $observed 'pc' $null
  $gw = [string](Get-FsProp $pc 'gw' ''); if ($gw) { return (Get-FsP3 $gw) }
  $s = [string](Get-FsProp $expected 'scheme' ''); if ($s) { return $s }
  $ip = [string](Get-FsProp $pc 'ip' ''); if ($ip) { return (Get-FsP3 $ip) }
  return ''
}

# ---------------- password candidates (Moshe Nov 3 5:24 PM: saved ones first, then ONE question, then the official reset) ----------------
function Get-FsPasswordCandidates($store, [int]$max = 3) {
  # store: { password (the site's current one), known:[...] (typed on earlier runs, worked), usual:[...] (WireIt's usual ones) }
  # returns @(@{ label; value }) in the order to try, no duplicates, never more than $max. Values are only handed to the login call.
  $out = New-Object System.Collections.ArrayList; $seen = @{}
  $add = { param($label, $v) if ($v -and -not $seen.ContainsKey([string]$v) -and $out.Count -lt $max) { $seen[[string]$v] = 1; [void]$out.Add([pscustomobject]@{ label = $label; value = [string]$v }) } }
  & $add 'site password' (Get-FsProp $store 'password' '')
  $i = 0; foreach ($k in @(Get-FsProp $store 'known' @())) { $i++; & $add ('site password ' + $i) $k }
  $i = 0; foreach ($u in @(Get-FsProp $store 'usual' @())) { $i++; & $add ('WireIt usual ' + $i) $u }
  return @($out)
}

# ---------------- matching what is there with what should be there ----------------
function Find-FsMatch($exp, $obsList, $used) {
  $mac = ConvertTo-FsMac ([string](Get-FsProp $exp 'mac' '')); $sn = [string](Get-FsProp $exp 'serial' ''); $ip = [string](Get-FsProp $exp 'ip' '')
  foreach ($o in $obsList) { if ($used.ContainsKey($o.key)) { continue }; if ($mac -and (ConvertTo-FsMac ([string]$o.mac)) -eq $mac) { return $o } }
  if ($sn) { foreach ($o in $obsList) { if ($used.ContainsKey($o.key)) { continue }; $os = [string]$o.serial; if ($os -and ($os -eq $sn -or ($os.Length -ge 9 -and $sn.Length -ge 9 -and ($os.EndsWith($sn) -or $sn.EndsWith($os))))) { return $o } } }
  if ($ip -and -not $mac -and -not $sn) { foreach ($o in $obsList) { if ($used.ContainsKey($o.key)) { continue }; if ([string]$o.ip -eq $ip) { return $o } } }
  return $null
}

function ConvertTo-FsObserved($observed) {
  # one list of devices; NVR channel info attached to the camera that answers on that IP
  $devs = New-Object System.Collections.ArrayList; $n = 0
  foreach ($d in @(Get-FsProp $observed 'devices' @())) {
    $n++; $mac = ConvertTo-FsMac ([string](Get-FsProp $d 'mac' ''))
    $kind = [string](Get-FsProp $d 'kind' 'camera'); if (-not $kind) { $kind = 'camera' }
    [void]$devs.Add([pscustomobject]@{
      key = $(if ($mac) { $mac } else { 'dev' + $n }); mac = $mac; ip = [string](Get-FsProp $d 'ip' ''); mask = [string](Get-FsProp $d 'mask' '255.255.255.0'); gw = [string](Get-FsProp $d 'gw' '')
      brand = (Get-FsBrand ([string](Get-FsProp $d 'brand' '')) ([string](Get-FsProp $d 'model' '')) $mac); model = [string](Get-FsProp $d 'model' ''); serial = [string](Get-FsProp $d 'serial' '')
      firmware = [string](Get-FsProp $d 'firmware' ''); kind = $kind; activated = (Get-FsProp $d 'activated' $true); dhcp = [bool](Get-FsProp $d 'dhcp' $false)
      answers = (Get-FsProp $d 'answers' $true); name = [string](Get-FsProp $d 'name' ''); login = [string](Get-FsProp $d 'login' '')
      streams = (Get-FsProp $d 'streams' $null); channel = $null; nvr = ''; online = $null; chName = ''; chProtocol = ''
    })
  }
  foreach ($nv in @(Get-FsProp $observed 'nvrs' @())) {
    $nip = [string](Get-FsProp $nv 'ip' '')
    foreach ($c in @(Get-FsProp $nv 'channels' @())) {
      $cip = [string](Get-FsProp $c 'ip' ''); if (-not $cip) { continue }
      $hit = $null; foreach ($d in $devs) { if ($d.ip -eq $cip -and $d.kind -ne 'nvr') { $hit = $d; break } }
      if ($hit) { $hit.channel = [int](Get-FsProp $c 'channel' 0); $hit.nvr = $nip; $hit.online = (Get-FsProp $c 'online' $null); $hit.chName = [string](Get-FsProp $c 'name' ''); $hit.chProtocol = [string](Get-FsProp $c 'protocol' ''); if (-not $hit.name) { $hit.name = $hit.chName } }
    }
  }
  return $devs
}

function Get-FsChannelFor($observed, [string]$ip, [int]$channel) {
  foreach ($nv in @(Get-FsProp $observed 'nvrs' @())) {
    foreach ($c in @(Get-FsProp $nv 'channels' @())) {
      if (($ip -and [string](Get-FsProp $c 'ip' '') -eq $ip) -or ($channel -gt 0 -and [int](Get-FsProp $c 'channel' 0) -eq $channel)) { return [pscustomobject]@{ nvr = [string](Get-FsProp $nv 'ip' ''); ch = $c } }
    }
  }
  return $null
}

# ---------------- target address ----------------
function Get-FsTargetIp([string]$scheme, [string]$curIp, [int]$channel, [string]$listIp, $used, $o, [string]$ownIp = '') {
  # used: hashtable of last octets already taken (observed devices, list addresses of other devices, targets given out)
  # ownIp: an address reserved for THIS camera (its site-list address, or the address its NVR channel looks for) - taken first
  $first = [int]$o.camFirst; $last = [int]$o.camLast
  $free = { param($n) return ($n -ge $first -and $n -le $last -and -not $used.ContainsKey([int]$n)) }
  if ($ownIp -and (Get-FsP3 $ownIp) -eq $scheme -and $used[(Get-FsLast $ownIp)] -eq 'own:' + $ownIp) { return $ownIp }
  if ($listIp -and (Get-FsP3 $listIp) -eq $scheme) { $n = Get-FsLast $listIp; if (& $free $n) { return ($scheme + '.' + $n) } }
  if ($channel -gt 0) { $n = [int]$o.channelBase + $channel; if (& $free $n) { return ($scheme + '.' + $n) } }
  $n = Get-FsLast $curIp; if (& $free $n) { return ($scheme + '.' + $n) }
  for ($n = $first; $n -le $last; $n++) { if (& $free $n) { return ($scheme + '.' + $n) } }
  return ''
}

# ---------------- camera settings (Moshe Nov 3 2:14 PM: drop-downs, no presets; H.264 only for old/problem cameras) ----------------
function Test-FsOldFirmware([string]$fw) {
  # firmware built in 2020 or earlier counts as old (the BYW Dahua cams: V2.800 build 2020-06-28; Hikvision writes "build 200316")
  $m = [regex]::Match([string]$fw, '(20\d{2})-(\d{2})-(\d{2})'); if ($m.Success) { return ([int]$m.Groups[1].Value -le 2020) }
  $m = [regex]::Match([string]$fw, '(?i)build\s*(\d{2})(\d{2})(\d{2})\b'); if ($m.Success) { return ((2000 + [int]$m.Groups[1].Value) -le 2020) }
  return $false
}
function Test-FsProblemCam($cam, [string]$nvrBrand) {
  if ($cam.why -match 'no video|hung|not answering') { return $true }
  if ($nvrBrand -and $cam.brand -ne 'Unknown' -and $nvrBrand -ne $cam.brand -and $cam.nvr) { return $true }   # ONVIF camera on another brand's NVR (Dahua on Hikvision)
  if (Test-FsOldFirmware $cam.firmware) { return $true }
  return $false
}
function Get-FsWantedSettings($choice, [bool]$problem, $perCam) {
  # what this camera should get. Everything left at "keep" (0 / 'keep') is not touched.
  $w = [ordered]@{ codec = 'keep'; fps = 0; resolution = 'keep'; bitrate = 0; gop = 0; smartCodec = 'keep' }
  $c = [string](Get-FsProp $choice 'codec' 'auto')
  if ($c -eq 'auto') { if ($problem) { $w.codec = 'H.264' } } elseif ($c -in @('H.264', 'H.265')) { $w.codec = $c }
  $w.fps = [int](Get-FsProp $choice 'fps' 0); $w.resolution = [string](Get-FsProp $choice 'resolution' 'keep'); $w.bitrate = [int](Get-FsProp $choice 'bitrate' 0)
  $sc = [string](Get-FsProp $choice 'smartCodecOff' 'problem'); if ($sc -eq 'all' -or ($sc -eq 'problem' -and $problem)) { $w.smartCodec = 'off' }
  if ($perCam) {
    foreach ($k in @('codec', 'resolution')) { $v = [string](Get-FsProp $perCam $k ''); if ($v) { $w[$k] = $v } }
    foreach ($k in @('fps', 'bitrate')) { $v = [int](Get-FsProp $perCam $k 0); if ($v -gt 0) { $w[$k] = $v } }
  }
  if ([bool](Get-FsProp $choice 'gopIsFps' $true)) { $w.gop = -1 }   # -1 = I-frame interval equals the frame rate (1 per second)
  return [pscustomobject]$w
}
function Get-FsSettingsDiff($current, $wanted) {
  # current: { codec, fps, width, height, bitrate, gop, smartCodec ('on'|'off'), maxWidth, maxHeight } of the main stream.
  # returns @(@{ field; from; to }) - empty means nothing to change (safe to re-run).
  $out = @()
  if (-not $current) { return $out }
  $cc = [string](Get-FsProp $current 'codec' ''); $cf = [int](Get-FsProp $current 'fps' 0)
  if ($wanted.codec -ne 'keep' -and $cc -and ($cc -replace '[^0-9A-Za-z]', '') -ne ($wanted.codec -replace '[^0-9A-Za-z]', '')) { $out += [pscustomobject]@{ field = 'codec'; from = $cc; to = $wanted.codec } }
  $fps = $cf; if ($wanted.fps -gt 0 -and $cf -ne $wanted.fps) { $out += [pscustomobject]@{ field = 'fps'; from = $cf; to = $wanted.fps }; $fps = $wanted.fps }
  if ($wanted.resolution -ne 'keep') {
    $tw = 0; $th = 0
    if ($wanted.resolution -eq 'max') { $tw = [int](Get-FsProp $current 'maxWidth' 0); $th = [int](Get-FsProp $current 'maxHeight' 0) }
    else { $m = [regex]::Match($wanted.resolution, '(\d+)\s*x\s*(\d+)'); if ($m.Success) { $tw = [int]$m.Groups[1].Value; $th = [int]$m.Groups[2].Value } }
    $cw = [int](Get-FsProp $current 'width' 0); $ch = [int](Get-FsProp $current 'height' 0)
    if ($tw -gt 0 -and ($cw -ne $tw -or $ch -ne $th)) { $out += [pscustomobject]@{ field = 'resolution'; from = ('' + $cw + 'x' + $ch); to = ('' + $tw + 'x' + $th) } }
  }
  $cb = [int](Get-FsProp $current 'bitrate' 0); if ($wanted.bitrate -gt 0 -and $cb -ne $wanted.bitrate) { $out += [pscustomobject]@{ field = 'bitrate'; from = $cb; to = $wanted.bitrate } }
  $cg = [int](Get-FsProp $current 'gop' 0); if ($wanted.gop -eq -1 -and $fps -gt 0 -and $cg -ne $fps) { $out += [pscustomobject]@{ field = 'gop'; from = $cg; to = $fps } }
  $cs = [string](Get-FsProp $current 'smartCodec' ''); if ($wanted.smartCodec -eq 'off' -and $cs -eq 'on') { $out += [pscustomobject]@{ field = 'smartCodec'; from = 'on'; to = 'off' } }
  return $out
}
function Format-FsSettingsDiff($diff) {
  $p = @(); foreach ($d in @($diff)) {
    switch ($d.field) {
      'codec' { $p += ([string]$d.to + ' (was ' + $d.from + ')') } 'fps' { $p += ([string]$d.to + ' fps') } 'resolution' { $p += [string]$d.to }
      'bitrate' { $p += ([string]$d.to + ' kbps') } 'gop' { $p += ('I-frame ' + $d.to) } 'smartCodec' { $p += 'Smart Codec off' }
    }
  }
  return ($p -join ', ')
}

# ---------------- THE PLAN ----------------
function New-FsPlan($expected, $observed, $opts = $null) {
  <# Returns:
     { scheme, site, hasList, nvrs:[...], cams:[{ key, name, brand, model, mac, serial, ip, target, channel, nvr, switch, port, state ('ok'|'fix'|'missing'|'manual'),
       why:[plain words], steps:[ids], login, problem, settings(wanted) }], healthy:[names], missing:[...], unknownPw:[...], notes:[...] }
     steps: backup, password, reset (official, needs a human step), activate (human), settings, move, nvr, reboot, poe, verify #>
  $o = Merge-FsOptions $opts
  $scheme = Get-FsScheme $observed $expected
  $obs = @(ConvertTo-FsObserved $observed)
  $hasList = [bool]($expected -and @(Get-FsProp $expected 'cameras' @()).Count)
  $used = @{}   # last octets on the right scheme that are taken
  foreach ($d in $obs) { if ((Get-FsP3 $d.ip) -eq $scheme) { $used[(Get-FsLast $d.ip)] = 1 } }
  foreach ($h in 1..9) { $used[$h] = 1 }
  $pcIp = [string](Get-FsProp (Get-FsProp $observed 'pc' $null) 'ip' ''); if ((Get-FsP3 $pcIp) -eq $scheme) { $used[(Get-FsLast $pcIp)] = 1 }
  $gwIp = [string](Get-FsProp (Get-FsProp $observed 'pc' $null) 'gw' ''); if ($gwIp) { $used[(Get-FsLast $gwIp)] = 1 }
  $ports = Get-FsProp $observed 'ports' $null
  $plan = [ordered]@{ version = $script:FsVersion; scheme = $scheme; site = [string](Get-FsProp $expected 'site' ''); hasList = $hasList; nvrs = @(); cams = @(); healthy = @(); missing = @(); unknownPw = @(); notes = @(); pc = (Get-FsProp $observed 'pc' $null) }
  if (-not $scheme) { $plan.notes += 'This PC has no router address, so the right IP scheme is unknown. Plug the PC into the site network and run again.' }

  # --- NVRs ---
  $nvrBrand = ''
  $expNvrs = @(Get-FsProp $expected 'nvrs' @())
  foreach ($nv in @(Get-FsProp $observed 'nvrs' @())) {
    $ip = [string](Get-FsProp $nv 'ip' ''); $br = Get-FsBrand ([string](Get-FsProp $nv 'brand' '')) ([string](Get-FsProp $nv 'model' '')); if (-not $nvrBrand) { $nvrBrand = $br }
    $item = [ordered]@{ ip = $ip; brand = $br; model = [string](Get-FsProp $nv 'model' ''); mac = (ConvertTo-FsMac ([string](Get-FsProp $nv 'mac' ''))); login = [string](Get-FsProp $nv 'login' ''); target = ''; why = @(); steps = @() }
    if ($scheme -and (Get-FsP3 $ip) -ne $scheme) {
      $t = ''; foreach ($h in $o.nvrHosts) { if (-not $used.ContainsKey([int]$h)) { $t = $scheme + '.' + $h; break } }
      foreach ($en in $expNvrs) { $eip = [string](Get-FsProp $en 'ip' ''); if ((ConvertTo-FsMac ([string](Get-FsProp $en 'mac' ''))) -eq $item.mac -and (Get-FsP3 $eip) -eq $scheme -and -not $used.ContainsKey((Get-FsLast $eip))) { $t = $eip } }
      if ($t) { $used[(Get-FsLast $t)] = 1; $item.target = $t; $item.why += ('NVR is on the wrong IP scheme (' + $ip + ', site is ' + $scheme + '.x)'); $item.steps += @('backup', 'move') }
      else { $item.why += 'NVR is on the wrong IP scheme and .20/.19/.18 are all taken'; $item.steps += 'manual' }
      if ($br -ne 'Hikvision') { $item.steps = @('manual'); $item.why += ('moving a ' + $br + ' NVR is not built yet: use Fix NVR / its own menu') }
    }
    if ($item.login -eq 'unknown') { $item.why += 'NVR password not known (asked once before the fixes)' }
    $plan.nvrs += [pscustomobject]$item
  }
  $nvrIpMap = @{}; foreach ($n in $plan.nvrs) { if ($n.target) { $nvrIpMap[$n.ip] = $n.target } }

  # --- cameras: list first, then whatever else is there ---
  $usedObs = @{}; $pairs = @()
  foreach ($e in @(Get-FsProp $expected 'cameras' @())) { $m = Find-FsMatch $e $obs $usedObs; if ($m) { $usedObs[$m.key] = 1 }; $pairs += , @($e, $m) }
  foreach ($d in $obs) { if ($d.kind -eq 'camera' -and -not $usedObs.ContainsKey($d.key)) { $pairs += , @($null, $d) } }
  # the list's own addresses are reserved for the cameras they belong to
  foreach ($pr in $pairs) { $e = $pr[0]; if ($e) { $lip = [string](Get-FsProp $e 'ip' ''); if ((Get-FsP3 $lip) -eq $scheme -and -not $used.ContainsKey((Get-FsLast $lip))) { $used[(Get-FsLast $lip)] = 'own:' + $lip } } }
  # no list: a camera on the wrong scheme and an NVR channel with no video are paired when it is one-to-one (or in order, marked as a guess)
  $guess = @{}
  $lostCams = @($pairs | Where-Object { -not $_[0] -and $_[1] -and $scheme -and (Get-FsP3 $_[1].ip) -ne $scheme -and -not $_[1].nvr -and -not (Test-FsPoeNet $_[1].ip) } | ForEach-Object { $_[1] } | Sort-Object { [version]$_.ip })
  $lostChs = @(); foreach ($nv in @(Get-FsProp $observed 'nvrs' @())) { foreach ($cc in @(Get-FsProp $nv 'channels' @())) { $cip = [string](Get-FsProp $cc 'ip' ''); if ((Get-FsProp $cc 'online' $true) -eq $false -and $cip -and -not @($obs | Where-Object { $_.ip -eq $cip }).Count -and -not @($pairs | Where-Object { $_[0] -and [string](Get-FsProp $_[0] 'ip' '') -eq $cip }).Count) { $lostChs += [pscustomobject]@{ nvr = [string](Get-FsProp $nv 'ip' ''); channel = [int](Get-FsProp $cc 'channel' 0); ip = $cip; name = [string](Get-FsProp $cc 'name' '') } } } }
  $lostChs = @($lostChs | Sort-Object channel)
  if ($lostCams.Count -and $lostCams.Count -eq $lostChs.Count) {
    for ($i = 0; $i -lt $lostCams.Count; $i++) { $guess[$lostCams[$i].key] = [pscustomobject]@{ ch = $lostChs[$i]; sure = ($lostCams.Count -eq 1) }; if ((Get-FsP3 $lostChs[$i].ip) -eq $scheme -and -not $used.ContainsKey((Get-FsLast $lostChs[$i].ip))) { $used[(Get-FsLast $lostChs[$i].ip)] = 'own:' + $lostChs[$i].ip } }
  }

  foreach ($pr in $pairs) {
    $e = $pr[0]; $d = $pr[1]
    $ch = [int](Get-FsProp $d 'channel' 0); if (-not $ch) { $ch = [int](Get-FsProp $e 'channel' 0) }
    $mac = $(if ($d) { $d.mac } else { ConvertTo-FsMac ([string](Get-FsProp $e 'mac' '')) })
    $sw = [string](Get-FsProp $e 'switch' ''); $port = Get-FsProp $e 'port' $null
    if ($ports -and $mac) { $pp = Get-FsProp $ports $mac $null; if ($pp) { if (-not $sw) { $sw = [string](Get-FsProp $pp 'switch' '') }; if ($null -eq $port) { $port = Get-FsProp $pp 'port' $null } } }
    $c = [ordered]@{ key = $(if ($d) { $d.key } else { 'list:' + $mac + ':' + (Get-FsProp $e 'ip' '') }); name = (Get-FsCamName $e $d)
      brand = $(if ($d) { $d.brand } else { Get-FsBrand ([string](Get-FsProp $e 'brand' '')) ([string](Get-FsProp $e 'model' '')) }); model = $(if ($d) { $d.model } else { [string](Get-FsProp $e 'model' '') })
      mac = $mac; serial = $(if ($d) { $d.serial } else { [string](Get-FsProp $e 'serial' '') }); firmware = $(if ($d) { $d.firmware } else { '' })
      ip = $(if ($d) { $d.ip } else { '' }); listIp = [string](Get-FsProp $e 'ip' ''); target = ''; channel = $ch; nvr = $(if ($d -and $d.nvr) { $d.nvr } else { [string](Get-FsProp $e 'nvr' '') })
      switch = $sw; port = $port; state = 'ok'; why = @(); steps = @(); login = $(if ($d) { $d.login } else { '' }); problem = $false; settings = $null; onList = [bool]$e; online = $(if ($d) { $d.online } else { $null }) }
    $ownIp = ''; $chLooksAt = $null
    if ($d -and $guess.ContainsKey($d.key)) { $g = $guess[$d.key]; $c.channel = $g.ch.channel; $ch = $g.ch.channel; $c.nvr = $g.ch.nvr; $ownIp = $g.ch.ip; if ($g.ch.name -and $c.name -like 'Camera *') { $c.name = $g.ch.name }; $chLooksAt = $g.ch.ip; if (-not $g.sure) { $c.why += ('matched to NVR ch ' + $g.ch.channel + ' by order (no site list): check the picture name after') } }
    elseif ($e) { $ownIp = $c.listIp; if ($ch -and $d -and -not $d.nvr) { $ci = Get-FsChannelFor $observed '' $ch; if ($ci) { $c.nvr = $ci.nvr; $chLooksAt = [string](Get-FsProp $ci.ch 'ip' '') } } }
    if ($c.nvr -and $nvrIpMap.ContainsKey($c.nvr)) { $c.nvr = $nvrIpMap[$c.nvr] }
    if (-not $d) {
      $c.state = 'missing'
      $where = $(if ($sw -and $null -ne $port) { 'should be on ' + $sw + ' port ' + $port + ': go check port ' + $port } elseif ($null -ne $port) { 'should be on switch port ' + $port + ': go check port ' + $port } else { 'its switch port is not on the site list: check its cable and power' })
      $c.why += ('missing - ' + $where)
      $chInfo = Get-FsChannelFor $observed $c.listIp $ch
      if ($chInfo -and $c.listIp) { $c.why[0] = ('missing (NVR ch ' + (Get-FsProp $chInfo.ch 'channel' $ch) + ' has no video) - ' + $where) }
      if ($null -ne $port -and $sw) { $c.steps += @('poe', 'verify') }
      $plan.missing += [pscustomobject]$c; $plan.cams += [pscustomobject]$c; continue
    }
    if (Test-FsPoeNet $d.ip) { $c.state = 'ok'; $c.why += 'on the NVR''s own PoE ports (left as is)'; $plan.healthy += $c.name; $plan.cams += [pscustomobject]$c; continue }
    # what is wrong
    $wrongScheme = ($scheme -and (Get-FsP3 $d.ip) -ne $scheme)
    $outOfBlock = (-not $wrongScheme -and $o.moveOutOfBlock -and ((Get-FsLast $d.ip) -lt [int]$o.camFirst -or (Get-FsLast $d.ip) -gt [int]$o.camLast))
    $listMove = (-not $wrongScheme -and -not $outOfBlock -and $c.listIp -and (Get-FsP3 $c.listIp) -eq $scheme -and $c.listIp -ne $d.ip -and -not (@($obs | Where-Object { $_.ip -eq $c.listIp -and $_.key -ne $d.key }).Count))
    if ($wrongScheme) { $c.why += ('wrong IP scheme (' + $d.ip + ', site is ' + $scheme + '.x)') }
    elseif ($outOfBlock) { $c.why += ('address ' + (Get-FsShort $d.ip) + ' is outside the camera block .' + $o.camFirst + '-.' + $o.camLast) }
    elseif ($listMove) { $c.why += ('site list says ' + (Get-FsShort $c.listIp) + ', it is on ' + (Get-FsShort $d.ip)) }
    if ($d.dhcp -and -not $wrongScheme -and -not $outOfBlock -and -not $listMove) { $c.why += 'gets its address from the router (DHCP), will be set fixed' }
    if ($d.activated -eq $false) { $c.why += 'brand new / factory reset (not activated)' }
    if ($d.answers -eq $false) { $c.why += 'hung - seen on the network but not answering' }
    if ($c.nvr -and $d.online -eq $false) { $c.why += ('no video on NVR ch ' + $ch) }
    if ($chLooksAt) { $c.why += ('no video on NVR ch ' + $ch + ' (it looks for ' + (Get-FsShort $chLooksAt) + ')') }
    elseif ($e -and $ch -and -not $d.nvr -and @(Get-FsProp $observed 'nvrs' @()).Count) { $c.why += ('not on the NVR (list says ch ' + $ch + ')') }
    # password
    $lg = $d.login
    if ($d.activated -eq $false) { $c.steps += 'activate' }
    elseif ($lg -eq 'unknown' -or $lg -eq 'refused') { $c.why += 'password unknown'; $c.steps += 'reset'; $plan.unknownPw += $c.name }
    elseif ($lg -eq 'locked') { $c.why += 'locked after wrong passwords (wait 30 min, or official reset)'; $c.steps += 'reset'; $plan.unknownPw += $c.name }
    elseif ($lg -and $lg -ne 'site password' -and $o.passwordAll) { $c.steps += 'password' }
    # settings
    $c.problem = Test-FsProblemCam ([pscustomobject]$c) $nvrBrand
    $c.settings = Get-FsWantedSettings $o.settings $c.problem (Get-FsProp $e 'settings' $null)
    $diff = @(); if ($d.streams) { $diff = @(Get-FsSettingsDiff $d.streams $c.settings) }
    $wantsAny = ($c.settings.codec -ne 'keep' -or $c.settings.fps -gt 0 -or $c.settings.resolution -ne 'keep' -or $c.settings.bitrate -gt 0 -or $c.settings.smartCodec -eq 'off')
    if ($diff.Count) { $c.steps += 'settings'; $shown = @($diff | Where-Object { $_.field -ne 'gop' }); if ($shown.Count) { $c.why += ('settings: ' + (Format-FsSettingsDiff $shown)) } }   # I-frame = FPS is routine: not listed on its own
    elseif (-not $d.streams -and ($wantsAny -or $c.settings.gop -eq -1) -and ($c.why.Count -or $c.steps.Count)) { $c.steps += 'settings' }
    # address
    if ($wrongScheme -or $outOfBlock -or $listMove -or ($d.dhcp)) {
      if ($listMove) { $t = $c.listIp } elseif (-not $wrongScheme -and -not $outOfBlock) { $t = $d.ip } else { $t = Get-FsTargetIp $scheme $d.ip $ch $c.listIp $used $o $ownIp }
      if ($t) { $c.target = $t; $used[(Get-FsLast $t)] = 1; $c.steps += 'move' } else { $c.why += 'no free address left in .21-.99'; $c.steps += 'manual' }
    }
    # recorder
    $nvrNeeded = ($c.nvr -and ($c.target -or ($c.steps -contains 'password') -or ($c.steps -contains 'reset') -or $d.online -eq $false -or $chLooksAt)) -or ($e -and $ch -and -not $d.nvr -and @(Get-FsProp $observed 'nvrs' @()).Count)
    if ($nvrNeeded) { $c.steps += 'nvr' }
    if ($d.answers -eq $false) { if ($sw -and $null -ne $port) { $c.steps += 'poe' } else { $c.steps += 'unplug' } }
    elseif ($c.nvr -and $d.online -eq $false -and -not $c.target -and $c.steps -notcontains 'reset') { $c.steps += 'reboot' }
    if ($c.steps.Count) { $c.steps = @('backup') + @($c.steps) + @('verify'); $c.state = 'fix' } else { $c.state = 'ok'; $plan.healthy += $c.name }
    if ($c.steps -contains 'manual') { $c.state = 'manual' }
    if (-not $e -and $hasList -and $c.state -ne 'ok') { $c.why += 'not on the site list' }
    $plan.cams += [pscustomobject]$c
  }
  if (-not $hasList) { $plan.notes += 'This site has no camera list yet. At the end you can save what was found as the site''s list.' }
  return [pscustomobject]$plan
}

# ---------------- plain words ----------------
function Get-FsStepWords($c) {
  $w = @()
  foreach ($s in @($c.steps)) {
    switch ($s) {
      'move' { if ($c.target -ne $c.ip) { $w += ('move ' + $c.ip + ' -> ' + (Get-FsShort $c.target)) } else { $w += 'set its address fixed' } }
      'password' { $w += 'set the site password' }
      'reset' { $w += 'official password reset (one step for you)' }
      'activate' { $w += 'activate with the site password (one step for you)' }
      'settings' { $w += 'camera settings' }
      'nvr' { if ($c.channel) { $w += ('back on NVR ch ' + $c.channel) } else { $w += 'back on the NVR' } }
      'reboot' { $w += 'restart it' }
      'poe' { $w += ('power-cycle ' + $c.switch + ' port ' + $c.port) }
      'unplug' { $w += 'unplug its cable 10 s (one step for you)' }
      'manual' { $w += 'needs a hand fix (see why)' }
    }
  }
  return ($w -join ', ')
}

function Format-FsPlan($plan) {
  # the confirm screen: only problems, healthy cameras in one line
  $L = New-Object System.Collections.Generic.List[string]
  $fix = @($plan.cams | Where-Object { $_.state -eq 'fix' }); $miss = @($plan.cams | Where-Object { $_.state -eq 'missing' }); $man = @($plan.cams | Where-Object { $_.state -eq 'manual' })
  $nv = @($plan.nvrs | Where-Object { $_.steps.Count })
  if (-not $fix.Count -and -not $miss.Count -and -not $man.Count -and -not $nv.Count) {
    $L.Add('Nothing to fix. ' + @($plan.healthy).Count + ' cameras are fine.'); foreach ($n in $plan.notes) { $L.Add('Note: ' + $n) }; return $L
  }
  foreach ($n in $nv) { $L.Add('NVR ' + $n.ip + ': ' + ($n.why -join '; ') + $(if ($n.target) { '  ->  will move to ' + (Get-FsShort $n.target) } else { '' })) }
  # simple ones (only the site password) collapse into one line
  $simple = @($fix | Where-Object { (@($_.steps | Where-Object { $_ -notin @('backup', 'password', 'settings', 'nvr', 'verify') }).Count -eq 0) -and -not @($_.why | Where-Object { $_ }).Count })
  $rest = @($fix | Where-Object { $simple -notcontains $_ })
  foreach ($c in $rest) { $L.Add($c.name + ' (' + $(if ($c.ip) { $c.ip } else { 'no IP' }) + '): ' + (@($c.why) -join '; ') + '  ->  ' + (Get-FsStepWords $c)) }
  if ($simple.Count) { $L.Add('' + $simple.Count + ' working camera(s) only get the site password' + $(if (@($simple | Where-Object { $_.steps -contains 'settings' }).Count) { ' and I-frame = frame rate' } else { '' }) + ': ' + (@($simple | ForEach-Object { $_.name }) -join ', ')) }
  foreach ($c in $miss) { $L.Add($c.name + $(if ($c.listIp) { ' (' + $c.listIp + $(if ($c.channel) { ', NVR ch ' + $c.channel } else { '' }) + ')' } else { '' }) + ': ' + (@($c.why) -join '; ') + $(if ($c.steps -contains 'poe') { '  ->  will power-cycle that port, then look again' } else { '' })) }
  foreach ($c in $man) { $L.Add($c.name + ' (' + $c.ip + '): ' + (@($c.why) -join '; ') + '  ->  not changed, fix by hand') }
  if (@($plan.healthy).Count) { $L.Add('' + @($plan.healthy).Count + ' other camera(s) are fine.') }
  foreach ($n in $plan.notes) { $L.Add('Note: ' + $n) }
  return $L
}

function Get-FsOrderKey($c) {
  # fix order: cameras that need a person (official reset, unplug) last; then by address - same order on PowerShell 5.1 and 7
  $pri = $(if ($c.steps -contains 'reset' -or $c.steps -contains 'activate' -or $c.steps -contains 'unplug') { 1 } else { 0 })
  $ip = [string]$(if ($c.ip) { $c.ip } else { $c.listIp }); $n = 0L; foreach ($o in ($ip -split '\.')) { $v = 0; [void][int]::TryParse($o, [ref]$v); $n = $n * 256 + $v }
  return ('{0}-{1:D12}-{2}' -f $pri, $n, $c.name)
}

function Format-FsCheckLine([string]$name, $results) {
  # results: @(@{ text; ok ($true/$false/$null = skipped) }) -> "Lobby cam: moved .55 -> .23 [ok], password set [ok], back on NVR ch 5 [ok]"
  $p = @(); foreach ($r in @($results)) { if (-not $r) { continue }; $mark = $(if ($r.ok -eq $true) { $script:FsOk } elseif ($r.ok -eq $false) { $script:FsBad } else { '' }); $p += (([string]$r.text) + $(if ($mark) { ' ' + $mark } else { '' })) }
  return ($name + ': ' + ($p -join ', '))
}
$script:FsOk = [string][char]0x2705; $script:FsBad = [string][char]0x274C

# ---------------- the site list ----------------
function New-FsSiteList([string]$site, [string]$siteId, $plan, $observed) {
  # "Save this as the site's list": what is there now, after the fixes (targets where a camera was moved). No passwords.
  $cams = @(); foreach ($c in @($plan.cams | Where-Object { $_.state -ne 'missing' })) {
    $ip = $(if ($c.target) { $c.target } else { $c.ip })
    $cams += [ordered]@{ name = $c.name; brand = $c.brand; model = $c.model; serial = $c.serial; mac = $c.mac; ip = $ip; channel = $c.channel; nvr = $c.nvr; switch = $c.switch; port = $c.port }
  }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'missing' })) { $cams += [ordered]@{ name = $c.name; brand = $c.brand; model = $c.model; serial = $c.serial; mac = $c.mac; ip = $c.listIp; channel = $c.channel; nvr = $c.nvr; switch = $c.switch; port = $c.port } }
  $nvrs = @(); foreach ($n in @($plan.nvrs)) { $nvrs += [ordered]@{ brand = $n.brand; model = $n.model; mac = $n.mac; ip = $(if ($n.target) { $n.target } else { $n.ip }) } }
  return [ordered]@{ site = $site; siteId = $siteId; scheme = $plan.scheme; saved = (Get-Date -Format 's'); savedBy = ('WireIt Toolkit ' + $script:FsVersion + ' on ' + $env:COMPUTERNAME); note = 'No passwords in this file.'; nvrs = $nvrs; cameras = $cams }
}

function ConvertFrom-FsSnapshot($snap) {
  # an install snapshot from Fix NVR ("FixNVR snapshot <site> <date>.json") is a ready-made site list
  $cams = @()
  foreach ($c in @(Get-FsProp $snap 'cameras' @())) { $cams += [ordered]@{ name = ''; brand = [string](Get-FsProp $c 'brand' ''); model = [string](Get-FsProp $c 'model' ''); serial = [string](Get-FsProp $c 'serial' ''); mac = (ConvertTo-FsMac ([string](Get-FsProp $c 'mac' ''))); ip = [string](Get-FsProp $c 'ip' ''); channel = [int](Get-FsProp $c 'channel' 0); nvr = [string](Get-FsProp $c 'nvr' ''); switch = ''; port = (Get-FsProp $c 'poe_port' $null) } }
  $nvrs = @(); foreach ($n in @(Get-FsProp $snap 'nvrs' @())) { $nvrs += [ordered]@{ brand = [string](Get-FsProp $n 'brand' ''); model = [string](Get-FsProp $n 'model' ''); mac = (ConvertTo-FsMac ([string](Get-FsProp $n 'mac' ''))); ip = [string](Get-FsProp $n 'ip' '') } }
  return [pscustomobject]@{ site = [string](Get-FsProp $snap 'site' ''); scheme = [string](Get-FsProp $snap 'scheme' ''); nvrs = $nvrs; cameras = $cams; from = 'install snapshot' }
}

function Add-FsPortMap($list, $portmapSite) {
  # PortMap's per-site file (C:\WireIt\PortMap\out\<WI-###>.json on the office Dell): camera -> switch + port, by MAC. Fills blanks only.
  if (-not $list -or -not $portmapSite) { return $list }
  $byMac = @{}; foreach ($pc in @(Get-FsProp $portmapSite 'cameras' @())) { $m = ConvertTo-FsMac ([string](Get-FsProp $pc 'mac' '')); if ($m) { $byMac[$m] = $pc } }
  foreach ($c in @(Get-FsProp $list 'cameras' @())) {
    $m = ConvertTo-FsMac ([string](Get-FsProp $c 'mac' '')); if (-not $m -or -not $byMac.ContainsKey($m)) { continue }; $pc = $byMac[$m]
    $set = { param($k, $v) if ($c -is [Collections.IDictionary]) { if (-not $c[$k]) { $c[$k] = $v } } else { if (-not (Get-FsProp $c $k $null)) { if ($c.PSObject.Properties[$k]) { $c.$k = $v } else { $c | Add-Member -NotePropertyName $k -NotePropertyValue $v } } } }
    & $set 'switch' ([string](Get-FsProp $pc 'switch_name' '')); & $set 'port' (Get-FsProp $pc 'port' $null); & $set 'name' ([string](Get-FsProp $pc 'camera_name' ''))
  }
  return $list
}
function Get-FsPortsFromPortMap($portmapSite) {
  $h = @{}; foreach ($pc in @(Get-FsProp $portmapSite 'cameras' @())) { $m = ConvertTo-FsMac ([string](Get-FsProp $pc 'mac' '')); if ($m) { $h[$m] = [pscustomobject]@{ switch = [string](Get-FsProp $pc 'switch_name' ''); port = (Get-FsProp $pc 'port' $null); poe_w = (Get-FsProp $pc 'poe_watts' $null); siteId = [string](Get-FsProp $pc 'site_id' '') } } }
  return $h
}

function Find-FsSiteFolder([string]$site, [string[]]$roots) {
  # the site's Drive folder: exact name, then the Site ID (WI-###) or words inside a folder name, then a folder that holds a site list with that Site ID
  if (-not $site) { return $null }; $s = $site.Trim()
  foreach ($root in @($roots)) {
    $r = [Environment]::ExpandEnvironmentVariables([string]$root); if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
    $dirs = @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' })
    $f = $dirs | Where-Object { $_.Name -eq $s } | Select-Object -First 1
    if (-not $f) { $f = $dirs | Where-Object { $_.Name -like ('*' + $s + '*') } | Select-Object -First 1 }
    if (-not $f -and $s -match '^(?i)WI-\d+$') {
      foreach ($d in $dirs) { $lp = Join-Path (Join-Path $d.FullName 'Docs') 'WireIt site list.json'; if (Test-Path -LiteralPath $lp) { try { $j = Get-Content -LiteralPath $lp -Raw | ConvertFrom-Json; if ([string]$j.siteId -eq $s) { $f = $d; break } } catch {} } }
    }
    if ($f) { return $f.FullName }
  }
  return $null
}

# ---------------- what the Toolkit window shows from a Fix this site run's log ----------------
function ConvertFrom-FsLog([string[]]$lines) {
  # log lines: "HH:mm:ss SAY text" (what the tool said), "HH:mm:ss ASK question", "HH:mm:ss ANSWER ..." - other lines (device chatter) are not shown
  $show = New-Object System.Collections.Generic.List[string]; $waiting = ''
  foreach ($l in @($lines)) {
    $m = [regex]::Match([string]$l, '^\d\d:\d\d:\d\d (SAY|ASK|ANSWER) ?(.*)$'); if (-not $m.Success) { continue }
    switch ($m.Groups[1].Value) { 'SAY' { $show.Add($m.Groups[2].Value) } 'ASK' { $waiting = $m.Groups[2].Value } 'ANSWER' { $waiting = '' } }
  }
  return [pscustomobject]@{ lines = @($show); waiting = $waiting }
}
function Get-FsExitWords([int]$code) {
  switch ($code) {
    0 { return 'Done. Everything is fixed.' }
    4 { return 'Done, but some things still need you: see the lines marked with a red X.' }
    2 { return 'Stopped. Nothing was changed.' }
    default { return ('It stopped unexpectedly (code ' + $code + '). Nothing is half-done: the run folder has the log and the undo file.') }
  }
}
function Get-FsLastRun([string]$runsDir, [switch]$Undoable) {
  if (-not (Test-Path -LiteralPath $runsDir)) { return $null }
  foreach ($d in @(Get-ChildItem -LiteralPath $runsDir -Directory -Filter 'FixSite-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
    if ($Undoable) { if ((Test-Path (Join-Path $d.FullName 'rollback.json')) -and -not (Test-Path (Join-Path $d.FullName 'undone.txt'))) { return $d } } else { return $d }
  }
  return $null
}
