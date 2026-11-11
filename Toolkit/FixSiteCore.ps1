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
$script:FsVersion = '2.2.16'
$script:FsPoeNets = @('192.168.254')

function Get-FsDefaults {
  [ordered]@{
    nvrHosts = @(20, 19, 18); camFirst = 21; camLast = 99; gearFirst = 10; gearLast = 19; routerFirst = 100; channelBase = 20
    moveOutOfBlock = $true          # a camera WITH A REAL PROBLEM on the right scheme but outside .21-.99 (e.g. .150 in the router's range) is moved too; a working one is left where it is (2.0.1)
    passwordAll = $false            # 2.0.1/2.0.3: only when 'Make every device use the site password' is ticked (FixSite.ps1 -PasswordAll); a working camera is otherwise never touched
    factoryToSite = $false          # 2.0.3: a new site, or a site with no site password saved yet: every device still on its factory password gets the site password
    newSite = $false                # 2.0.2: started with the "New site (not listed)" button: no list, no site secrets; the plan screen says so first
    settingsAll = $false            # 2.0.1: only when 'Apply settings to ALL cameras' is ticked (FixSite.ps1 -AllCameras); drop-downs otherwise go only on cameras with a real problem
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
# 2.2.1 (review H9): the PC's REAL subnet (not always /24). $script:FsSubnet = { ip; prefix } of the site adapter, set by New-FsPlan / FixSite.
$script:FsSubnet = $null
function ConvertTo-FsIpNum([string]$ip) { if (-not $ip -or $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $null }; $o = $ip -split '\.'; foreach ($x in $o) { if ([int]$x -gt 255) { return $null } }; return ([uint32]([uint32]$o[0] * 16777216 + [uint32]$o[1] * 65536 + [uint32]$o[2] * 256 + [uint32]$o[3])) }
function ConvertTo-FsMask([int]$prefix) {
  # 24 -> 255.255.255.0, 22 -> 255.255.252.0 (anything out of 1..32 = /24)
  if ($prefix -lt 1 -or $prefix -gt 32) { $prefix = 24 }
  $m = [uint32]0; for ($i = 0; $i -lt $prefix; $i++) { $m = [uint32]($m + [uint32][math]::Pow(2, 31 - $i)) }
  return ('' + (($m -shr 24) -band 255) + '.' + (($m -shr 16) -band 255) + '.' + (($m -shr 8) -band 255) + '.' + ($m -band 255))
}
function ConvertTo-FsPrefix([string]$mask) { $n = ConvertTo-FsIpNum $mask; if ($null -eq $n) { return 0 }; $c = 0; for ($i = 31; $i -ge 0; $i--) { if (($n -band [uint32][math]::Pow(2, $i)) -ne 0) { $c++ } else { break } }; return $c }
function Test-FsInSubnet([string]$ip, [string]$netIp, [int]$prefix) {
  $a = ConvertTo-FsIpNum $ip; $b = ConvertTo-FsIpNum $netIp; if ($null -eq $a -or $null -eq $b -or $prefix -lt 1 -or $prefix -gt 32) { return $false }
  $sh = 32 - $prefix; if ($sh -ge 32) { return $true }
  return ([math]::Floor($a / [math]::Pow(2, $sh)) -eq [math]::Floor($b / [math]::Pow(2, $sh)))
}
# "on the site's scheme" = the same /24 as the router (WireIt standard) OR anywhere inside the PC's real subnet when it is bigger than /24
# (a /22 office: 192.168.5.x is NOT on a wrong scheme when the router is 192.168.4.1). Smaller than /24: the /24 AND inside the subnet.
function Test-FsOnScheme([string]$ip, [string]$scheme) {
  if (-not $ip -or -not $scheme) { return $false }
  $sn = $script:FsSubnet; $pre = 24; if ($sn -and [int]$sn.prefix -gt 0) { $pre = [int]$sn.prefix }
  if ($pre -lt 24) { return ((Get-FsP3 $ip) -eq $scheme -or (Test-FsInSubnet $ip ([string]$sn.ip) $pre)) }
  if ($pre -gt 24) { return ((Get-FsP3 $ip) -eq $scheme -and (Test-FsInSubnet $ip ([string]$sn.ip) $pre)) }
  return ((Get-FsP3 $ip) -eq $scheme)
}
# 2.2.1 (review M6): the main window always fits the screen's working area (768-pixel-high laptops at 150%), and scrolls if it must
function Get-FsWindowFit([double]$scale, [int]$workW, [int]$workH, [int]$wantW = 820, [int]$wantH = 640, [int]$minW = 700, [int]$minH = 560) {
  $w = [int]($wantW * $scale); $h = [int]($wantH * $scale); $mw = [int]($minW * $scale); $mh = [int]($minH * $scale)
  $roomW = [math]::Max(320, $workW - 16); $roomH = [math]::Max(240, $workH - 48)   # 48 = the title bar and borders
  $scroll = ($mw -gt $roomW -or $mh -gt $roomH)
  return [pscustomobject]@{ width = [int][math]::Min($w, $roomW); height = [int][math]::Min($h, $roomH); minWidth = [int][math]::Min($mw, $roomW); minHeight = [int][math]::Min($mh, $roomH); scroll = $scroll; scrollWidth = $mw; scrollHeight = $mh }
}
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
  $ip = [string](Get-FsProp $pc 'ip' ''); if ($ip -and $ip -notlike '169.254.*') { return (Get-FsP3 $ip) }   # 2.2.2 (H9): a 169.254 address is no site scheme
  return ''
}

# ---------------- 2.2.3 (Codex #8, #9): discovery belongs to THIS run and THIS network ----------------
function Test-FsFreshScan([string]$file, $exitCode, [datetime]$since) {
  # the finder's out\latest.json is used only when the finder ended OK and wrote it during this run
  if ($null -ne $exitCode -and [int]$exitCode -ne 0) { return $false }
  if (-not $file -or -not (Test-Path -LiteralPath $file)) { return $false }
  return ((Get-Item -LiteralPath $file).LastWriteTime -ge $since.AddSeconds(-2))
}
function Select-FsFoundOnNet($found, $pc, $pcAll) {
  # drops devices that sit inside one of this PC's OTHER networks (not the one the tech picked): they belong to that network
  $others = @(@($pcAll) | Where-Object { $_ -and [string]$_.ip -and [string]$_.ip -ne [string]$pc.ip -and [int]$_.prefix -gt 0 })
  return @(@($found) | Where-Object {
    $ip = [string]$_.ip; $mine = ($pc -and [int]$pc.prefix -gt 0 -and (Test-FsInSubnet $ip ([string]$pc.ip) ([int]$pc.prefix)))
    $mine -or -not @($others | Where-Object { Test-FsInSubnet $ip ([string]$_.ip) ([int]$_.prefix) }).Count })
}

# ---------------- password candidates (Moshe Nov 3 5:24 PM: saved ones first, then ONE question, then the official reset) ----------------
function Get-FsFactoryPasswords([string]$brand) {
  # 2.0.2 (new site): the makers' old factory passwords, tried LAST and inside the same try limit (cameras made since ~2017 have none: they must be activated)
  switch ($brand) { 'Hikvision' { return @('12345') } 'Dahua' { return @('admin') } 'Uniview' { return @('123456') } default { return @() } }
}
function Get-FsPasswordCandidates($store, [int]$max = 3, [string]$mac = '', [string[]]$defaults = @()) {
  # store: { password (the site's own password), known:[...] (typed on earlier runs at THIS site, worked),
  #          cams:{ mac: the password that last worked on that camera } (2.0.1: working cameras keep their own password now, so it is tried first) }
  # returns @(@{ label; value }) in the order to try, no duplicates, never more than $max. Values are only handed to the login call.
  # 2.2.3 (Codex #37): passwords are case-sensitive: SitePass9 and sitepass9 are two candidates (a PowerShell @{} is not)
  $out = New-Object System.Collections.ArrayList; $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $add = { param($label, $v) if ($v -and -not $seen.Contains([string]$v) -and $out.Count -lt $max) { [void]$seen.Add([string]$v); [void]$out.Add([pscustomobject]@{ label = $label; value = [string]$v }) } }
  $sitePw = [string](Get-FsProp $store 'password' ''); $known = @(Get-FsProp $store 'known' @())
  $m = ConvertTo-FsMac $mac; $cams = Get-FsProp $store 'cams' $null
  if ($m -and $cams) {
    $last = [string]$(if ($cams -is [Collections.IDictionary]) { $cams[$m] } else { Get-FsProp $cams $m '' })
    if ($last) {
      $lbl = 'saved camera password'
      if ($last -ceq $sitePw) { $lbl = 'site password' } else { $ix = [array]::IndexOf([string[]]@($known), $last); if ($ix -ge 0) { $lbl = 'site password ' + ($ix + 1) } }
      & $add $lbl $last
    }
  }
  & $add 'site password' $sitePw
  $i = 0; foreach ($k in $known) { $i++; & $add ('site password ' + $i) $k }
  foreach ($f in @($defaults)) { & $add 'factory default' $f }   # new site / no site password yet: last, still capped at $max (2.0.3: no shared passwords between sites)
  return @($out)
}

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
      streams = (Get-FsProp $d 'streams' $null); channel = $null; nvr = ''; online = $null; chName = ''; chProtocol = ''; links = @()
    })
  }
  foreach ($nv in @(Get-FsProp $observed 'nvrs' @())) {
    $nip = [string](Get-FsProp $nv 'ip' '')
    foreach ($c in @(Get-FsProp $nv 'channels' @())) {
      $cip = [string](Get-FsProp $c 'ip' ''); if (-not $cip) { continue }
      $hit = $null; foreach ($d in $devs) { if ($d.ip -eq $cip -and $d.kind -ne 'nvr') { $hit = $d; break } }
      # 2.2.3 (Codex #14): every recorder that records this camera is kept (links); the first stays its main NVR/channel
      if ($hit) { $hit.links += [pscustomobject]@{ nvr = $nip; channel = [int](Get-FsProp $c 'channel' 0); online = (Get-FsProp $c 'online' $null) } }   # 2.2.14 (Codex 2.2.13 F1): each channel's own video state
      if ($hit -and $hit.nvr) { continue }
      if ($hit) { $hit.channel = [int](Get-FsProp $c 'channel' 0); $hit.nvr = $nip; $hit.online = (Get-FsProp $c 'online' $null); $hit.chName = [string](Get-FsProp $c 'name' ''); $hit.chProtocol = [string](Get-FsProp $c 'protocol' ''); if (-not $hit.name) { $hit.name = $hit.chName } }
    }
  }
  return $devs
}

function Get-FsChannelFor($observed, [string]$ip, [int]$channel, [string]$nvrIp = '') {
  # 2.2.3 (Codex #14): an address match wins (on the named NVR first); a channel NUMBER alone only counts on the NVR the site list
  # names (or when the site has just one NVR): ch 3 of another recorder is another camera.
  $nvs = @(Get-FsProp $observed 'nvrs' @())
  if ($ip) {
    foreach ($pass in 1, 2) { foreach ($nv in $nvs) { $nip = [string](Get-FsProp $nv 'ip' ''); if ($pass -eq 1 -and $nvrIp -and $nip -ne $nvrIp) { continue }
      foreach ($c in @(Get-FsProp $nv 'channels' @())) { if ([string](Get-FsProp $c 'ip' '') -eq $ip) { return [pscustomobject]@{ nvr = $nip; ch = $c } } } } }
  }
  if ($channel -gt 0) {
    foreach ($nv in $nvs) {
      $nip = [string](Get-FsProp $nv 'ip' '')
      if ($nvrIp) { if ($nip -ne $nvrIp) { continue } } elseif ($nvs.Count -ne 1) { continue }
      foreach ($c in @(Get-FsProp $nv 'channels' @())) { if ([int](Get-FsProp $c 'channel' 0) -eq $channel) { return [pscustomobject]@{ nvr = $nip; ch = $c } } }
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
function Get-FsWantedSettings($choice, [bool]$problem, $perCam, [bool]$onlyPicked = $false) {
  # what this camera should get. Everything left at "keep" (0 / 'keep') is not touched.
  # $onlyPicked (2.0.1): a WORKING camera when "Apply settings to ALL cameras" is ticked - it gets only what was picked in the
  # drop-downs: no automatic H.264, no smart-codec change, no per-camera list settings, and I-frame = frame rate only when a frame rate was picked.
  $w = [ordered]@{ codec = 'keep'; fps = 0; resolution = 'keep'; bitrate = 0; gop = 0; smartCodec = 'keep' }
  $c = [string](Get-FsProp $choice 'codec' 'auto')
  if ($c -eq 'auto') { if ($problem -and -not $onlyPicked) { $w.codec = 'H.264' } } elseif ($c -in @('H.264', 'H.265')) { $w.codec = $c }
  $w.fps = [int](Get-FsProp $choice 'fps' 0); $w.resolution = [string](Get-FsProp $choice 'resolution' 'keep'); $w.bitrate = [int](Get-FsProp $choice 'bitrate' 0)
  if ($onlyPicked) {
    if ([bool](Get-FsProp $choice 'gopIsFps' $true) -and $w.fps -gt 0) { $w.gop = -1 }
    return [pscustomobject]$w
  }
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
# 2.2.12 (Codex 2.2.11 #4): what the camera REALLY has after a settings write. $after = Get-FsStream read back; returns the plain
# words for every requested field the camera does not have (empty = all confirmed). No read-back = every field unconfirmed.
function Get-FsStreamMismatch($after, $diff) {
  $out = @()
  foreach ($d in @($diff)) {
    if (-not $d) { continue }
    $f = [string]$d.field
    if (-not $after) { $out += ($f + ' not confirmed (the camera''s settings could not be read back)'); continue }
    switch ($f) {
      'codec' { $h = [string](Get-FsProp $after 'codec' ''); if (($h -replace '[^0-9A-Za-z]', '') -ne ([string]$d.to -replace '[^0-9A-Za-z]', '')) { $out += ('asked ' + $d.to + ', camera has ' + $(if ($h) { $h } else { '?' })) } }
      'fps' { $h = [int](Get-FsProp $after 'fps' 0); if ($h -ne [int]$d.to) { $out += ('asked ' + $d.to + ' fps, camera still has ' + $h) } }
      'bitrate' { $h = [int](Get-FsProp $after 'bitrate' 0); if ($h -ne [int]$d.to) { $out += ('asked ' + $d.to + ' kbps, camera has ' + $h) } }
      'gop' { $h = [int](Get-FsProp $after 'gop' 0); if ($h -ne [int]$d.to) { $out += ('asked I-frame ' + $d.to + ', camera has ' + $h) } }
      'resolution' { $h = ('' + [int](Get-FsProp $after 'width' 0) + 'x' + [int](Get-FsProp $after 'height' 0)); if ($h -ne [string]$d.to) { $out += ('asked ' + $d.to + ', camera has ' + $h) } }
      'smartCodec' { $h = [string](Get-FsProp $after 'smartCodec' ''); if ($h -ne 'off') { $out += ('asked Smart Codec off, camera has ' + $(if ($h) { $h } else { '?' })) } }
      'smartCodecOn' { $h = [string](Get-FsProp $after 'smartCodec' ''); if ($h -ne 'on') { $out += ('asked Smart Codec on, camera has ' + $(if ($h) { $h } else { '?' })) } }
      default { $out += ($f + ' not confirmed') }
    }
  }
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
  # 2.2.1 (review H9): the PC's real subnet decides what is "on the right scheme" (a /22 is not four wrong /24s)
  $pc0 = Get-FsProp $observed 'pc' $null; $pre0 = [int](Get-FsProp $pc0 'prefix' 0); if (-not $pre0) { $pre0 = ConvertTo-FsPrefix ([string](Get-FsProp $pc0 'mask' '')) }
  $script:FsSubnet = $(if ($pre0 -gt 0 -and [string](Get-FsProp $pc0 'ip' '')) { [pscustomobject]@{ ip = [string](Get-FsProp $pc0 'ip' ''); prefix = $pre0 } } else { $null })
  $obs = @(ConvertTo-FsObserved $observed)
  $hasList = [bool]($expected -and @(Get-FsProp $expected 'cameras' @()).Count)
  $used = @{}   # last octets on the right scheme that are taken
  foreach ($d in $obs) { if ((Get-FsP3 $d.ip) -eq $scheme) { $used[(Get-FsLast $d.ip)] = 1 } }
  foreach ($h in 1..9) { $used[$h] = 1 }
  $pcIp = [string](Get-FsProp (Get-FsProp $observed 'pc' $null) 'ip' ''); if ((Get-FsP3 $pcIp) -eq $scheme) { $used[(Get-FsLast $pcIp)] = 1 }
  $gwIp = [string](Get-FsProp (Get-FsProp $observed 'pc' $null) 'gw' ''); if ($gwIp) { $used[(Get-FsLast $gwIp)] = 1 }
  $ports = Get-FsProp $observed 'ports' $null
  $plan = [ordered]@{ version = $script:FsVersion; scheme = $scheme; site = [string](Get-FsProp $expected 'site' ''); hasList = $hasList; nvrs = @(); cams = @(); healthy = @(); missing = @(); unknownPw = @(); notes = @(); leftAlone = @(); settingsAll = [bool]$o.settingsAll; passwordAll = [bool]$o.passwordAll; pc = (Get-FsProp $observed 'pc' $null); newSite = [bool]$o.newSite }
  if (-not $scheme) { $plan.notes += 'This PC has no router address, so the right IP scheme is unknown. Plug the PC into the site network and run again.' }

  # --- NVRs ---
  $nvrBrand = ''
  $expNvrs = @(Get-FsProp $expected 'nvrs' @())
  foreach ($nv in @(Get-FsProp $observed 'nvrs' @())) {
    $ip = [string](Get-FsProp $nv 'ip' ''); $br = Get-FsBrand ([string](Get-FsProp $nv 'brand' '')) ([string](Get-FsProp $nv 'model' '')); if (-not $nvrBrand) { $nvrBrand = $br }
    $item = [ordered]@{ ip = $ip; brand = $br; model = [string](Get-FsProp $nv 'model' ''); mac = (ConvertTo-FsMac ([string](Get-FsProp $nv 'mac' ''))); login = [string](Get-FsProp $nv 'login' ''); target = ''; why = @(); steps = @(); chCount = @(Get-FsProp $nv 'channels' @()).Count; chRead = [bool](Get-FsProp $nv 'channelsRead' $true) }
    if (-not (Test-FsBrandSupported $br 'nvr')) { $item.why += (Get-FsUnsupportedWhy $br 'nvr'); $item.steps = @('manual'); $plan.nvrs += [pscustomobject]$item; continue }   # 2.2.3 (Codex #28)
    if ($scheme -and -not (Test-FsOnScheme $ip $scheme)) {
      $t = ''; foreach ($h in $o.nvrHosts) { if (-not $used.ContainsKey([int]$h)) { $t = $scheme + '.' + $h; break } }
      foreach ($en in $expNvrs) { $eip = [string](Get-FsProp $en 'ip' ''); if ((ConvertTo-FsMac ([string](Get-FsProp $en 'mac' ''))) -eq $item.mac -and (Get-FsP3 $eip) -eq $scheme -and -not $used.ContainsKey((Get-FsLast $eip))) { $t = $eip } }
      if ($t) { $used[(Get-FsLast $t)] = 1; $item.target = $t; $item.why += ('NVR is on the wrong IP scheme (' + $ip + ', site is ' + $scheme + '.x)'); $item.steps += @('backup', 'move') }
      else { $item.why += 'NVR is on the wrong IP scheme and .20/.19/.18 are all taken'; $item.steps += 'manual' }
      if ($br -ne 'Hikvision') { $item.steps = @('manual'); $item.why += ('moving a ' + $br + ' NVR is not built yet: use Fix NVR / its own menu') }
    }
    elseif ($scheme -and (Get-FsLast $ip) -ge 0 -and @($o.nvrHosts | ForEach-Object { [int]$_ }) -notcontains (Get-FsLast $ip)) {
      # 2.0.2: right scheme, but not where the WireIt standard puts an NVR (.20, or .19/.18). It works, so it is only named, never moved.
      $plan.leftAlone += ('NVR ' + $ip + ': WireIt standard puts the NVR at .' + @($o.nvrHosts)[0] + ' (it works where it is, so it is not moved)')
    }
    # 2.2.3 (Codex #30): on the right scheme but with broken network settings (DHCP, another router, wrong mask, no DNS) = fixed in place
    $netBad = @(Get-FsNvrNetProblems (Get-FsProp $nv 'net' $null) (Get-FsProp $observed 'pc' $null))
    if ($scheme -and (Test-FsOnScheme $ip $scheme) -and $netBad.Count -and -not @($item.steps).Count) {
      if ($br -eq 'Hikvision') { $item.target = $ip; $item.why += ('NVR network settings: ' + ($netBad -join '; ')); $item.steps += @('backup', 'move') }
      else { $item.why += ('NVR network settings: ' + ($netBad -join '; ') + ' - fix them in its own menu'); $item.steps += 'manual' }
    }
    if ($item.login -eq 'unknown') { $item.why += 'NVR password not known (asked once before the fixes)' }
    # 2.1.0: a Hikvision NVR nobody can log in to gets Hikvision's official reset too (never the reset button)
    if ($br -eq 'Hikvision' -and $item.login -in @('unknown', 'refused', 'locked')) { $item.why += 'Hikvision''s official password reset (request file -> Hikvision''s page -> unlock file)'; $item.steps += 'reset' }
    # 2.0.3: the NVR gets the site password too - when it is still on the factory password at a new site, or when the tech ticked the option
    if ($br -eq 'Hikvision' -and $item.login -eq 'factory default' -and $o.factoryToSite) { $item.why += 'NVR still on the factory password'; $item.steps += 'password' }
    elseif ($br -eq 'Hikvision' -and $o.passwordAll -and $item.login -and $item.login -notin @('unknown', 'locked', 'refused', 'site password')) { $item.why += 'NVR is on a different password (you ticked "Make every device use the site password")'; $item.steps += 'password' }
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
  $lostCams = @($pairs | Where-Object { -not $_[0] -and $_[1] -and $scheme -and -not (Test-FsOnScheme $_[1].ip $scheme) -and -not $_[1].nvr -and -not (Test-FsPoeNet $_[1].ip) } | ForEach-Object { $_[1] } | Sort-Object { [version]$_.ip })
  $lostChs = @(); foreach ($nv in @(Get-FsProp $observed 'nvrs' @())) { foreach ($cc in @(Get-FsProp $nv 'channels' @())) { $cip = [string](Get-FsProp $cc 'ip' ''); if ((Get-FsProp $cc 'online' $true) -eq $false -and $cip -and -not @($obs | Where-Object { $_.ip -eq $cip }).Count -and -not @($pairs | Where-Object { $_[0] -and [string](Get-FsProp $_[0] 'ip' '') -eq $cip }).Count) { $lostChs += [pscustomobject]@{ nvr = [string](Get-FsProp $nv 'ip' ''); channel = [int](Get-FsProp $cc 'channel' 0); ip = $cip; name = [string](Get-FsProp $cc 'name' '') } } } }
  $lostChs = @($lostChs | Sort-Object channel)
  if ($lostCams.Count -and $lostCams.Count -eq $lostChs.Count) {
    for ($i = 0; $i -lt $lostCams.Count; $i++) { $guess[$lostCams[$i].key] = [pscustomobject]@{ ch = $lostChs[$i]; sure = ($lostCams.Count -eq 1) }; if ((Get-FsP3 $lostChs[$i].ip) -eq $scheme -and -not $used.ContainsKey((Get-FsLast $lostChs[$i].ip))) { $used[(Get-FsLast $lostChs[$i].ip)] = 'own:' + $lostChs[$i].ip } }
  }

  # 2.0.2: no list - the address an NVR channel with no video looks for stays free for that camera (nobody else is moved onto it)
  if (-not $hasList) { foreach ($lc in $lostChs) { if ((Get-FsP3 $lc.ip) -eq $scheme -and -not $used.ContainsKey((Get-FsLast $lc.ip))) { $used[(Get-FsLast $lc.ip)] = 1 } } }
  foreach ($pr in $pairs) {
    $e = $pr[0]; $d = $pr[1]
    $ch = [int](Get-FsProp $d 'channel' 0); if (-not $ch) { $ch = [int](Get-FsProp $e 'channel' 0) }
    $mac = $(if ($d) { $d.mac } else { ConvertTo-FsMac ([string](Get-FsProp $e 'mac' '')) })
    $sw = [string](Get-FsProp $e 'switch' ''); $port = Get-FsProp $e 'port' $null
    if ($ports -and $mac) { $pp = Get-FsProp $ports $mac $null; if ($pp) { if (-not $sw) { $sw = [string](Get-FsProp $pp 'switch' '') }; if ($null -eq $port) { $port = Get-FsProp $pp 'port' $null } } }
    $c = [ordered]@{ key = $(if ($d) { $d.key } else { 'list:' + $mac + ':' + (Get-FsProp $e 'ip' '') }); name = (Get-FsCamName $e $d)
      brand = $(if ($d) { $d.brand } else { Get-FsBrand ([string](Get-FsProp $e 'brand' '')) ([string](Get-FsProp $e 'model' '')) }); model = $(if ($d) { $d.model } else { [string](Get-FsProp $e 'model' '') })
      mac = $mac; serial = $(if ($d) { $d.serial } else { [string](Get-FsProp $e 'serial' '') }); firmware = $(if ($d) { $d.firmware } else { '' })
      ip = $(if ($d) { $d.ip } else { '' }); listIp = [string](Get-FsProp $e 'ip' ''); target = ''; channel = $ch; nvr = $(if ($d -and $d.nvr) { $d.nvr } else { [string](Get-FsProp $e 'nvr' '') }); listNvr = [string](Get-FsProp $e 'nvr' '')   # 2.2.12: the NVR the site list names (it may be offline today)
      switch = $sw; port = $port; state = 'ok'; why = @(); steps = @(); login = $(if ($d) { $d.login } else { '' }); problem = $false; broken = $true; pwOnly = $false; settings = $null; onList = [bool]$e; online = $(if ($d) { $d.online } else { $null }); links = $(if ($d) { @($d.links) } else { @() }) }
    $ownIp = ''; $chLooksAt = $null
    if ($d -and $guess.ContainsKey($d.key)) { $g = $guess[$d.key]; $c.channel = $g.ch.channel; $ch = $g.ch.channel; $c.nvr = $g.ch.nvr; $ownIp = $g.ch.ip; if ($g.ch.name -and $c.name -like 'Camera *') { $c.name = $g.ch.name }; $chLooksAt = $g.ch.ip; if (-not $g.sure) { $c.why += ('matched to NVR ch ' + $g.ch.channel + ' by order (no site list): check the picture name after') } }
    elseif ($e) { $ownIp = $c.listIp; if ($ch -and $d -and -not $d.nvr) { $ci = Get-FsChannelFor $observed '' $ch ([string](Get-FsProp $e 'nvr' '')); if ($ci) { $c.nvr = $ci.nvr; $chLooksAt = [string](Get-FsProp $ci.ch 'ip' '') } } }
    $c.nvrOriginal = [string]$c.nvr
    if ($c.nvr -and $nvrIpMap.ContainsKey($c.nvr)) { $c.nvr = $nvrIpMap[$c.nvr] }
    if (-not $d) {
      $c.state = 'missing'
      $where = $(if ($sw -and $null -ne $port) { 'should be on ' + $sw + ' port ' + $port + ': go check port ' + $port } elseif ($null -ne $port) { 'should be on switch port ' + $port + ': go check port ' + $port } else { 'its switch port is not on the site list: check its cable and power' })
      $c.why += ('missing - ' + $where)
      $chInfo = Get-FsChannelFor $observed $c.listIp $ch ([string](Get-FsProp $e 'nvr' ''))
      if ($chInfo -and $c.listIp) { $c.why[0] = ('missing (NVR ch ' + (Get-FsProp $chInfo.ch 'channel' $ch) + ' has no video) - ' + $where) }
      if ($null -ne $port -and $sw) { $c.steps += @('poe', 'verify') }
      $plan.missing += [pscustomobject]$c; $plan.cams += [pscustomobject]$c; continue
    }
    if (Test-FsPoeNet $d.ip) { $c.state = 'ok'; $c.broken = $false; $c.why += 'on the NVR''s own PoE ports (left as is)'; $plan.healthy += $c.name; $plan.cams += [pscustomobject]$c; continue }
    if (-not (Test-FsBrandSupported $c.brand 'camera')) { $c.state = 'manual'; $c.steps = @('manual'); $c.why += (Get-FsUnsupportedWhy $c.brand 'camera'); $plan.cams += [pscustomobject]$c; continue }   # 2.2.3 (Codex #28)
    # what is wrong
    $wrongScheme = ($scheme -and -not (Test-FsOnScheme $d.ip $scheme))
    $outOfBlock = (-not $wrongScheme -and $o.moveOutOfBlock -and ((Get-FsLast $d.ip) -lt [int]$o.camFirst -or (Get-FsLast $d.ip) -gt [int]$o.camLast))
    $listMove = (-not $wrongScheme -and -not $outOfBlock -and $c.listIp -and (Get-FsP3 $c.listIp) -eq $scheme -and $c.listIp -ne $d.ip -and -not (@($obs | Where-Object { $_.ip -eq $c.listIp -and $_.key -ne $d.key }).Count))
    if ($wrongScheme) { $c.why += ('wrong IP scheme (' + $d.ip + ', site is ' + $scheme + '.x)') }
    if ($wrongScheme -and -not $hasList -and -not $c.nvr -and $lostChs.Count -and -not $guess.ContainsKey($d.key)) { $c.why += ('which NVR channel it belongs to is not clear (' + $lostChs.Count + ' channel(s) without video for ' + $lostCams.Count + ' camera(s) on the wrong scheme) - it gets a free address; put it on its NVR channel by hand') }   # 2.0.2
    elseif ($outOfBlock) { $c.why += ('address ' + (Get-FsShort $d.ip) + ' is outside the camera block .' + $o.camFirst + '-.' + $o.camLast) }
    elseif ($listMove) { $c.why += ('site list says ' + (Get-FsShort $c.listIp) + ', it is on ' + (Get-FsShort $d.ip)) }
    if ($d.dhcp -and -not $wrongScheme -and -not $outOfBlock -and -not $listMove) { $c.why += 'gets its address from the router (DHCP), will be set fixed' }
    if ($d.activated -eq $false) { $c.why += 'brand new / factory reset (not activated)' }
    if ($d.answers -eq $false) { $c.why += 'hung - seen on the network but not answering' }
    if ($c.nvr -and $d.online -eq $false) { $c.why += ('no video on NVR ch ' + $ch) }
    if ($chLooksAt) { $c.why += ('no video on NVR ch ' + $ch + ' (it looks for ' + (Get-FsShort $chLooksAt) + ')') }
    elseif ($e -and $ch -and -not $d.nvr -and @(Get-FsProp $observed 'nvrs' @()).Count) { $c.why += ('not on the NVR (list says ch ' + $ch + ')') }
    # 2.0.1 (Moshe, Nov 3 10:06 PM: "I definitely don't want to make across the board changes if everything is working besides for three cameras"):
    # only a camera with a REAL problem gets any change. A working camera is not touched at all (no password, no settings, no I-frame, no address)
    # unless the tech ticked "Make every device use the site password" / "Apply settings to ALL cameras" for this run.
    # 2.0.3: one exception Moshe chose (Nov 4 3:35 PM): at a new site (no site password yet) a camera still on its FACTORY password gets the site password.
    $lg = $d.login
    $notOnNvr = [bool]($e -and $ch -and -not $d.nvr -and -not $chLooksAt -and @(Get-FsProp $observed 'nvrs' @()).Count)
    $hard = [bool]($wrongScheme -or $d.activated -eq $false -or $d.answers -eq $false -or ($c.nvr -and $d.online -eq $false) -or $chLooksAt -or $notOnNvr)
    $pwBad = ($lg -in @('unknown', 'refused', 'locked'))
    $videoOk = [bool]($c.nvr -and $d.online -eq $true)
    # a camera whose password we do not know but whose video is fine on the NVR is WORKING: no official reset for it
    $c.broken = [bool]($hard -or ($pwBad -and -not $videoOk))
    if ($pwBad -and -not $c.broken) { $c.why += $(if ($lg -eq 'locked') { 'locked after wrong passwords, but its video is fine on the NVR' } else { 'password not known, but its video is fine on the NVR' }) }
    if (-not $c.broken) {
      $tidy = @($c.why | Where-Object { $_ -match 'outside the camera block|site list says|DHCP|video is fine on the NVR' } | ForEach-Object { $_ -replace ', will be set fixed', '' })
      if ($lg -eq 'factory default' -and -not $o.factoryToSite -and -not $o.passwordAll) { $tidy += 'still on the factory password (tick "Make every device use the site password" to change it)' }   # 2.0.2
      if ($pwBad -and $o.passwordAll) { $tidy += 'password not known, so it cannot be switched to the site password' }
      if ($tidy.Count) { $plan.leftAlone += ($c.name + ' (' + $d.ip + '): ' + ($tidy -join '; ')) }
      $c.why = @()
      if ($lg -and -not $pwBad -and $lg -ne 'site password' -and ($o.passwordAll -or ($lg -eq 'factory default' -and $o.factoryToSite))) { $c.steps += 'password'; $c.pwOnly = $true }   # 2.0.3: rollback if its picture does not come back
      if ($o.settingsAll) {
        $c.settings = Get-FsWantedSettings $o.settings $false $null $true
        $wantsAny = ($c.settings.codec -ne 'keep' -or $c.settings.fps -gt 0 -or $c.settings.resolution -ne 'keep' -or $c.settings.bitrate -gt 0)
        $diff = @(); if ($d.streams) { $diff = @(Get-FsSettingsDiff $d.streams $c.settings) }
        if ($diff.Count -or (-not $d.streams -and $wantsAny)) { $c.steps += 'settings' }
      }
      if ($c.nvr -and $c.steps -contains 'password') { $c.steps += 'nvr' }   # the NVR channel gets the new password too, or the video drops
      if ($c.steps.Count) { $c.steps = @('backup') + @($c.steps) + @('verify'); $c.state = 'fix' } else { $c.state = 'ok'; $plan.healthy += $c.name }
      $plan.cams += [pscustomobject]$c; continue
    }
    # password
    $lg = $d.login
    if ($d.activated -eq $false) { $c.steps += 'activate' }
    elseif ($lg -eq 'unknown' -or $lg -eq 'refused') { $c.why += 'password unknown'; $c.steps += 'reset'; $plan.unknownPw += $c.name }
    elseif ($lg -eq 'locked') { $c.why += 'locked after wrong passwords (wait 30 min, or official reset)'; $c.steps += 'reset'; $plan.unknownPw += $c.name }
    elseif ($lg -and $lg -ne 'site password') { $c.steps += 'password' }   # a camera being fixed anyway gets the site password
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
  # 2.0.2: no list (a new site): "missing" = a camera the NVR has a channel for, with no video, that nothing answers for
  #        (a camera on the wrong scheme already paired to that channel above is not missing: it is being moved back).
  if (-not $hasList) {
    $taken = @{}; foreach ($gk in @($guess.Keys)) { $gc = $guess[$gk].ch; $taken[[string]$gc.nvr + '|' + [string]$gc.channel] = 1 }
    foreach ($lc in $lostChs) {
      if ($taken.ContainsKey([string]$lc.nvr + '|' + [string]$lc.channel)) { continue }
      $nvT = $(if ($nvrIpMap.ContainsKey([string]$lc.nvr)) { $nvrIpMap[[string]$lc.nvr] } else { [string]$lc.nvr })
      $c = [ordered]@{ key = ('nvrch:' + $lc.nvr + ':' + $lc.channel); name = $(if ($lc.name) { [string]$lc.name } else { 'Camera ch ' + $lc.channel }); brand = ''; model = ''; mac = ''; serial = ''; firmware = ''
        ip = ''; listIp = [string]$lc.ip; target = ''; channel = [int]$lc.channel; nvr = $nvT; nvrOriginal = [string]$lc.nvr; switch = ''; port = $null; state = 'missing'
        why = @('missing - NVR ch ' + $lc.channel + ' has no video and nothing answers at ' + $lc.ip + ': go check that camera (power, cable, switch port)')
        steps = @(); login = ''; problem = $false; broken = $true; pwOnly = $false; settings = $null; onList = $false; online = $false; fromNvr = $true }
      $plan.missing += [pscustomobject]$c; $plan.cams += [pscustomobject]$c
    }
  } else {
    # 2.2.16 (Codex 2.2.15 F1): with a site list, an NVR channel with no video that points at an address where nothing answers, and that
    # belongs to no camera of this run, is a problem too: e.g. a second NVR still on a camera's OLD address after the camera was moved
    # (its recording is lost). Never "Nothing to fix". Nothing is changed on it (the tool cannot tell which camera it should be).
    $taken = @{}
    foreach ($gk in @($guess.Keys)) { $gc = $guess[$gk].ch; $taken[[string]$gc.nvr + '|' + [string]$gc.channel] = 1 }
    foreach ($pcm in @($plan.cams)) {
      foreach ($x in @(Get-FsCamChannels $pcm)) { $taken[[string]$x.nvr + '|' + [string]$x.channel] = 1 }
      $po = [string](Get-FsProp $pcm 'nvrOriginal' ''); if ($po) { $taken[$po + '|' + [int](Get-FsProp $pcm 'channel' 0)] = 1 }
    }
    foreach ($lc in $lostChs) {
      $nvT = $(if ($nvrIpMap.ContainsKey([string]$lc.nvr)) { $nvrIpMap[[string]$lc.nvr] } else { [string]$lc.nvr })
      if ($taken.ContainsKey([string]$lc.nvr + '|' + [string]$lc.channel) -or $taken.ContainsKey($nvT + '|' + [string]$lc.channel)) { continue }
      $c = [ordered]@{ key = ('nvrch:' + $lc.nvr + ':' + $lc.channel); name = $(if ($lc.name) { [string]$lc.name } else { 'Camera ch ' + $lc.channel }); brand = ''; model = ''; mac = ''; serial = ''; firmware = ''
        ip = ''; listIp = [string]$lc.ip; target = ''; channel = [int]$lc.channel; nvr = $nvT; nvrOriginal = [string]$lc.nvr; switch = ''; port = $null; state = 'missing'
        why = @('NVR ' + $nvT + ' ch ' + $lc.channel + ' has NO video and nothing answers at ' + $lc.ip + ' (it is not on the site list). If a camera was moved, this channel still points at its old address: put the camera''s new address on this channel by hand, or check that camera (power, cable)')
        steps = @(); login = ''; problem = $false; broken = $true; pwOnly = $false; settings = $null; onList = $false; online = $false; fromNvr = $true; orphan = $true }
      $plan.missing += [pscustomobject]$c; $plan.cams += [pscustomobject]$c
    }
  }
  # 2.0.2: the router's own range against the standard (router hands out .100 and up). Only named; the Toolkit never changes the router.
  $pcO = Get-FsProp $observed 'pc' $null
  if ($pcO -and [bool](Get-FsProp $pcO 'dhcp' $false) -and (Get-FsP3 $pcIp) -eq $scheme -and (Get-FsLast $pcIp) -ge [int]$o.gearFirst -and (Get-FsLast $pcIp) -lt [int]$o.routerFirst) {
    $plan.notes += ('The router gave this PC ' + (Get-FsShort $pcIp) + '. WireIt standard: the router hands out .' + $o.routerFirst + ' and up, so it never gives away a camera or NVR address. Change the router''s DHCP range by hand (the Toolkit does not touch the router).')
  }
  # 2.2.1 (review H9): a site network smaller than a /24 - the Toolkit's .21-.99 / .20 standard does not fit inside it, so it moves nothing there
  if ($script:FsSubnet -and [int]$script:FsSubnet.prefix -gt 24) {
    foreach ($x in @(@($plan.cams) + @($plan.nvrs))) { if ($x.steps -contains 'move') { $x.steps = @('manual'); $x.why += ('this network is smaller than the usual one (mask ' + (ConvertTo-FsMask ([int]$script:FsSubnet.prefix)) + '), so its address is not changed by the Toolkit: set it by hand'); if ($x.PSObject.Properties['state']) { $x.state = 'manual' }; $x.target = '' } }
  }
  $sp = $o.settings
  if ($o.settingsAll -and [int](Get-FsProp $sp 'fps' 0) -le 0 -and [int](Get-FsProp $sp 'bitrate' 0) -le 0 -and [string](Get-FsProp $sp 'resolution' 'keep') -eq 'keep' -and [string](Get-FsProp $sp 'codec' 'auto') -notin @('H.264', 'H.265')) { $plan.notes += 'You ticked "Apply settings to ALL cameras" but every drop-down is on "keep", so no working camera gets new settings.' }
  if (-not $hasList -and -not $o.newSite) { $plan.notes += 'This site has no camera list yet. At the end you can save what was found as the site''s list.' }
  # 2.2.15 (Codex 2.2.14 R1): which recorders that may record each camera had their channel list NOT read at the scan (failed or
  # garbled answer, or no login). Its own known recorders count; a camera with no known recorder may be on any NVR there, so every
  # unread one counts. Non-empty = no password change, no address move, no official reset for it in this run (Still a problem).
  $unread = @{}; foreach ($n in @($plan.nvrs)) { if (-not (Get-FsProp $n 'chRead' $true)) { $unread[[string]$n.ip] = [string]$n.ip; if ($n.target) { $unread[[string]$n.target] = [string]$n.ip } } }
  foreach ($c in @($plan.cams)) {
    $u = @()
    # 2.2.16 (Codex 2.2.15 F1): a camera's KNOWN recorder(s) do not prove that an unread NVR does not ALSO record it (NVR .19 read,
    # .20 unread: .20 may have a channel on the camera too). Every unread NVR on the site is an unresolved dependency of every camera:
    # no password change, no move, no official reset in this run. Its own known recorders are named first.
    if ($unread.Count) {
      $recs = @(Get-FsCamRecorders $c)
      foreach ($r in $recs) { if ($unread.ContainsKey([string]$r) -and $u -notcontains $unread[[string]$r]) { $u += $unread[[string]$r] } }
      foreach ($v in @($unread.Values | Select-Object -Unique)) { if ($u -notcontains $v) { $u += $v } }
    }
    $c | Add-Member -NotePropertyName chUnknown -NotePropertyValue @($u) -Force
  }
  return [pscustomobject]$plan
}

# ---------------- plain words ----------------
function Get-FsStepWords($c) {
  $w = @()
  foreach ($s in @($c.steps)) {
    switch ($s) {
      'move' { if ($c.target -ne $c.ip) { $w += ('move ' + $c.ip + ' -> ' + (Get-FsShort $c.target)) } else { $w += 'set its address fixed' } }
      'password' { $w += 'set the site password' }
      'reset' { $w += $(if ($c.brand -eq 'Hikvision') { 'Hikvision''s official password reset, automatic (you only type the page''s picture check)' } else { 'official password reset (one step for you)' }) }
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

function Get-FsNewSiteLine($plan) {
  # 2.0.2: "New site (no saved list): found 1 NVR (10.0.5.20, 6 channels) and 5 cameras on 10.0.5.x, router 10.0.5.1. 1 NVR channel has no camera answering."
  $camsSeen = @($plan.cams | Where-Object { $_.state -ne 'missing' }); $chMiss = @($plan.cams | Where-Object { $_.state -eq 'missing' })
  $nv = @($plan.nvrs); $gw = [string](Get-FsProp (Get-FsProp $plan 'pc' $null) 'gw' '')
  $nvTxt = $(if (-not $nv.Count) { 'no NVR' } elseif ($nv.Count -eq 1) { '1 NVR (' + $nv[0].ip + $(if ([int]$nv[0].chCount) { ', ' + $nv[0].chCount + ' channels' } else { '' }) + ')' } else { '' + $nv.Count + ' NVRs (' + (@($nv | ForEach-Object { $_.ip }) -join ', ') + ')' })
  $line = 'New site (no saved list): found ' + $nvTxt + ' and ' + $camsSeen.Count + ' camera(s)' + $(if ($plan.scheme) { ' on ' + $plan.scheme + '.x' } else { '' }) + $(if ($gw) { ', router ' + $gw } else { '' }) + '.'
  if ($chMiss.Count) { $line += ' ' + $chMiss.Count + ' NVR channel(s) have no camera answering.' }
  return $line
}

function Format-FsPlan($plan) {
  # the confirm screen: only problems; working cameras in one "OK, not touched" line.
  # 2.0.1: the first line says exactly how many cameras change and how many are not touched (Moshe, Nov 3 10:06 PM).
  $L = New-Object System.Collections.Generic.List[string]
  $fix = @($plan.cams | Where-Object { $_.state -eq 'fix' }); $miss = @($plan.cams | Where-Object { $_.state -eq 'missing' }); $man = @($plan.cams | Where-Object { $_.state -eq 'manual' })
  $fixB = @($fix | Where-Object { $_.broken -ne $false }); $fixW = @($fix | Where-Object { $_.broken -eq $false })
  $missPoe = @($miss | Where-Object { $_.steps -contains 'poe' })
  $nv = @($plan.nvrs | Where-Object { $_.steps.Count })
  $hc = @($plan.healthy).Count
  $okLine = 'OK, not touched: ' + $hc + ' working camera(s)'
  if ($plan.PSObject.Properties['newSite'] -and $plan.newSite) { $L.Add((Get-FsNewSiteLine $plan)) }   # 2.0.2: first line on a new site
  if (-not $fix.Count -and -not $miss.Count -and -not $man.Count -and -not $nv.Count) {
    # 2.2.15 (Codex 2.2.14 R1): an NVR whose channel list could not be read leaves its channels NOT CHECKED: never "Nothing to fix"
    $unr = @($plan.nvrs | Where-Object { -not (Get-FsProp $_ 'chRead' $true) })
    if ($unr.Count) { $L.Add('NOT everything was checked: the camera channel list of NVR ' + (@($unr | ForEach-Object { $_.ip }) -join ', ') + ' could not be read. Nothing is changed. Run Fix this site again.') }
    else { $L.Add('Nothing to fix. ' + $hc + ' cameras are fine - nothing will be touched.') }
    foreach ($x in @($plan.leftAlone)) { $L.Add('Working, left as is: ' + $x) }
    foreach ($n in $plan.notes) { $L.Add('Note: ' + $n) }; return $L
  }
  $n = $fix.Count + $missPoe.Count
  $ticked = @(); if ($plan.passwordAll) { $ticked += '"Make every device use the site password"' }; if ($plan.settingsAll) { $ticked += '"Apply settings to ALL cameras"' }
  if (-not $n) { $L.Add('No camera gets changed. ' + $hc + ' working camera(s) will not be touched.') }
  elseif ($fixW.Count) { $L.Add('Changes the ' + $n + ' camera(s) listed below: ' + ($fixB.Count + $missPoe.Count) + ' with a problem + ' + $fixW.Count + ' working one(s) ' + $(if ($ticked.Count) { 'because you ticked ' + ($ticked -join ' and ') } else { 'still on the factory password' }) + '. ' + $hc + ' working camera(s) will not be touched.') }
  else { $L.Add('Changes only the ' + $n + ' camera(s) listed below. ' + $hc + ' working camera(s) will not be touched.') }
  $L.Add('')
  foreach ($nn in $nv) { $L.Add('NVR ' + $nn.ip + ': ' + ($nn.why -join '; ') + $(if ($nn.target) { '  ->  will move to ' + (Get-FsShort $nn.target) } else { '' }) + $(if ($nn.steps -contains 'password') { '  ->  gets the site password' } else { '' })) }
  foreach ($c in $fixB) { $L.Add($c.name + ' (' + $(if ($c.ip) { $c.ip } else { 'no IP' }) + '): ' + (@($c.why) -join '; ') + '  ->  ' + (Get-FsStepWords $c)) }
  foreach ($c in $miss) { $L.Add($c.name + $(if ($c.listIp) { ' (' + $c.listIp + $(if ($c.channel) { ', NVR ch ' + $c.channel } else { '' }) + ')' } else { '' }) + ': ' + (@($c.why) -join '; ') + $(if ($c.steps -contains 'poe') { '  ->  will power-cycle that port, then look again' } else { '' })) }
  foreach ($c in $man) { $L.Add($c.name + ' (' + $c.ip + '): ' + (@($c.why) -join '; ') + '  ->  not changed, fix by hand') }
  if ($fixW.Count) {
    $what = @(); if (@($fixW | Where-Object { $_.steps -contains 'password' }).Count) { $what += 'the site password' }; if (@($fixW | Where-Object { $_.steps -contains 'settings' }).Count) { $what += 'the drop-down settings' }
    $why = $(if ($plan.passwordAll -or $plan.settingsAll) { ' (you ticked it)' } else { ' (still on the factory password)' })
    $L.Add('' + $fixW.Count + ' working camera(s) get ONLY ' + ($what -join ' + ') + $why + ': ' + (@($fixW | ForEach-Object { $_.name }) -join ', '))
    if (@($fixW | Where-Object { $_.pwOnly }).Count) { $L.Add('Each one: new password -> its NVR channel updated -> picture checked. If the picture does not come back, its old password is put back.') }
  }
  if ($hc) { $L.Add($okLine) }
  foreach ($x in @($plan.leftAlone)) { $L.Add('Working, left as is: ' + $x) }
  foreach ($nn in $plan.notes) { $L.Add('Note: ' + $nn) }
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
function Resolve-FsPlanNvrAddresses($plan) {
  foreach ($c in @($plan.cams)) {
    $original = [string](Get-FsProp $c 'nvrOriginal' $c.nvr)
    $n = @($plan.nvrs | Where-Object { $_.ip -eq $original }) | Select-Object -First 1
    if ($n) { $c.nvr = $(if ($n.target -and (Get-FsProp $n 'moved' $false)) { [string]$n.target } else { [string]$n.ip }) }
  }
}
function New-FsSiteList([string]$site, [string]$siteId, $plan, $observed) {
  Resolve-FsPlanNvrAddresses $plan
  # "Save this as the site's list": what is there now, after the fixes (targets where a camera was moved). No passwords.
  $cams = @(); foreach ($c in @($plan.cams | Where-Object { $_.state -ne 'missing' })) {
    # 2.2.3 (Codex #38): where the camera IS now: the new address only when the move was verified (ipNow), never the planned one
    $ip = [string](Get-FsProp $c 'ipNow' ''); if (-not $ip) { $ip = [string]$c.ip }
    $cams += [ordered]@{ name = $c.name; brand = $c.brand; model = $c.model; serial = $c.serial; mac = $c.mac; ip = $ip; channel = $c.channel; nvr = $c.nvr; switch = $c.switch; port = $c.port }
  }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'missing' })) { $cams += [ordered]@{ name = $c.name; brand = $c.brand; model = $c.model; serial = $c.serial; mac = $c.mac; ip = $c.listIp; channel = $c.channel; nvr = $c.nvr; switch = $c.switch; port = $c.port } }
  $nvrs = @(); foreach ($n in @($plan.nvrs)) { $nvrs += [ordered]@{ brand = $n.brand; model = $n.model; mac = $n.mac; ip = $(if ($n.target -and (Get-FsProp $n 'moved' $false)) { $n.target } else { $n.ip }) } }
  return [ordered]@{ site = $site; siteId = $siteId; scheme = $plan.scheme; saved = (Get-Date -Format 's'); savedBy = ('WireIt Toolkit ' + $script:FsVersion + ' on ' + $env:COMPUTERNAME); note = 'No passwords in this file.'; nvrs = $nvrs; cameras = $cams }
}

# 2.2.3 (Codex #28): what Fix this site can really change. Recorders: Hikvision. Cameras: Hikvision and Dahua. Anything else
# (Uniview, unknown, other makers) is found and listed but never touched: the tool says so plainly and it counts as manual work.
function Test-FsBrandSupported([string]$brand, [string]$kind) {
  if ($kind -eq 'nvr') { return ($brand -eq 'Hikvision') }
  return ($brand -in @('Hikvision', 'Dahua'))
}
function Get-FsUnsupportedWhy([string]$brand, [string]$kind) {
  $b = $(if ($brand) { $brand } else { 'unknown-brand' })
  return ('Fix this site does not support ' + $b + ' ' + $(if ($kind -eq 'nvr') { 'recorders' } else { 'cameras' }) + ' - left exactly as it is; fix it in its own web page')
}
function Get-FsManualLines($plan) {
  # 2.2.3 (Codex #42): what needs a person (manual NVR steps, cameras the tool will not touch) is part of the result: each one is a
  # red checklist line and counts as "still a problem" (never a green "all fixed")
  $out = @()
  foreach ($n in @($plan.nvrs | Where-Object { @($_.steps) -contains 'manual' })) { $out += ('NVR ' + $n.ip + ': needs a person - ' + (@($n.why) -join '; ') + ' ' + $script:FsBad) }
  # 2.2.15 (Codex 2.2.14 R1): an NVR that logged in but whose channel list could not be read: its channels are NOT CHECKED - a
  # problem, never "Nothing to fix" (an NVR with no login is already a problem of its own)
  foreach ($n in @($plan.nvrs | Where-Object { -not (Get-FsProp $_ 'chRead' $true) -and @($_.steps) -notcontains 'manual' -and [string]$_.login -and [string]$_.login -notin @('unknown', 'locked', 'refused', 'not supported') })) { $out += ('NVR ' + $n.ip + ': its camera channel list could not be read - its channels are NOT CHECKED. So no camera on this site got a new password, a new address or the official reset in this run (any of them could be on that NVR). Run Fix this site again ' + $script:FsBad) }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'manual' })) { $out += ($c.name + ': needs a person - ' + (@($c.why) -join '; ') + ' ' + $script:FsBad) }
  # 2.2.14 (Codex 2.2.13 F1): ANOTHER channel that records this camera (a second channel on the same NVR, or another NVR) has no
  # video: that recording is lost, whatever the camera's main channel shows - a problem, never "OK, not touched"
  foreach ($c in @($plan.cams)) {
    $mn = [string](Get-FsProp $c 'nvr' ''); $mc = [int](Get-FsProp $c 'channel' 0)
    foreach ($x in @(Get-FsCamChannels $c)) {
      if ($x.nvr -eq $mn -and $x.channel -eq $mc) { continue }
      if ($x.online -eq $false) { $out += ($c.name + ': NVR ' + $x.nvr + ' ch ' + $x.channel + ' also records this camera and has NO video - check that channel in the NVR (its password or address) ' + $script:FsBad) }
    }
  }
  return $out
}
function Get-FsNvrNetProblems($net, $pc) {
  # what is wrong with an NVR's own network settings, against this PC's network (its router and mask). Unknown = nothing claimed.
  $p = @(); if (-not $net) { return $p }
  $pgw = [string](Get-FsProp $pc 'gw' ''); $pmask = [string](Get-FsProp $pc 'mask' '')
  if ([bool](Get-FsProp $net 'dhcp' $false)) { $p += 'gets its address from DHCP (it can change)' }
  $g = [string](Get-FsProp $net 'gw' ''); if ($pgw -and $g -ne $pgw) { $p += ('router ' + $(if ($g) { $g } else { 'none' }) + ' (the site router is ' + $pgw + ')') }
  $m = [string](Get-FsProp $net 'mask' ''); if ($pmask -and $m -and $m -ne $pmask) { $p += ('mask ' + $m + ' (site: ' + $pmask + ')') }
  if (-not [string](Get-FsProp $net 'dns1' '') -or [string](Get-FsProp $net 'dns1' '') -eq '0.0.0.0') { $p += 'no DNS server (no app / cloud access)' }
  return $p
}
# 2.2.12 (Codex 2.2.11 #1): every recorder known to record this camera: its main NVR (site list or scan) plus every NVR channel the
# scan found pointing at it. More than one = the camera's address is not changed by the tool (only one NVR would follow it).
function Get-FsCamRecorders($c) {
  $out = @(); $mn = [string](Get-FsProp $c 'nvr' ''); if ($mn) { $out += $mn }
  $ln = [string](Get-FsProp $c 'listNvr' '')
  # 2.2.13: the list's NVR that this run moved to a new address is the SAME recorder (its main NVR now), not a second one
  # (the scan's own channel links name it by the address it had at the scan too)
  $orig = [string](Get-FsProp $c 'nvrOriginal' '')
  if ($ln -and $mn -and $ln -eq $orig) { $ln = $mn }
  if ($ln -and $out -notcontains $ln) { $out += $ln }
  foreach ($l in @(Get-FsProp $c 'links' @())) { if (-not $l) { continue }; $v = [string](Get-FsProp $l 'nvr' ''); if ($v -and $mn -and $v -eq $orig) { $v = $mn }; if ($v -and $out -notcontains $v) { $out += $v } }
  return $out
}
# 2.2.14 (Codex 2.2.13 F1): every NVR CHANNEL that records this camera (not only every recorder): its main NVR channel plus every
# channel the scan found pointing at it - two channels on the SAME NVR (a second sensor/stream) are two dependents. Each item:
# nvr, channel, online ($true / $false / $null = not read). The list's NVR the run moved is the same recorder (as Get-FsCamRecorders).
function Get-FsCamChannels($c) {
  $out = @(); $seen = @{}
  $mn = [string](Get-FsProp $c 'nvr' ''); $orig = [string](Get-FsProp $c 'nvrOriginal' '')
  $links = @(Get-FsProp $c 'links' @() | Where-Object { $_ })
  foreach ($l in $links) {
    $v = [string](Get-FsProp $l 'nvr' ''); if (-not $v) { continue }; if ($mn -and $v -eq $orig) { $v = $mn }
    $n = [int](Get-FsProp $l 'channel' 0); $k = $v + '|' + $n; if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true
    $out += [pscustomobject]@{ nvr = $v; channel = $n; online = (Get-FsProp $l 'online' $null) }
  }
  if ($mn) {
    $mc = [int](Get-FsProp $c 'channel' 0); $k = $mn + '|' + $mc
    # a main NVR with no channel yet (the run puts it on one) is that NVR's link when the scan found one there
    $onIt = @($out | Where-Object { $_.nvr -eq $mn }).Count
    if (-not $seen.ContainsKey($k) -and -not ($mc -eq 0 -and $onIt)) { $out = @([pscustomobject]@{ nvr = $mn; channel = $mc; online = (Get-FsProp $c 'online' $null) }) + $out }
  }
  return $out
}
function Format-FsCamChannels($chs) { return ((@($chs) | ForEach-Object { 'NVR ' + $_.nvr + ' ch ' + $_.channel }) -join ', ') }
# 2.2.14 (Codex 2.2.13 F1): may this camera be MOVED to another address? '' = yes. Every recorder AND every channel that records it
# would have to follow; the tool updates and checks only one channel, so more than one dependent = it is not moved.
# 2.2.15 (Codex 2.2.14 R1): the NVRs that may record this camera whose channel list was not read (New-FsPlan's chUnknown)
function Get-FsCamUnreadNvrs($c) { return @(@(Get-FsProp $c 'chUnknown' @()) | Where-Object { $_ }) }
function Get-FsMoveBlock($c) {
  $rec = @(Get-FsCamRecorders $c)
  if ($rec.Count -gt 1) { return ('NOT moved: ' + $rec.Count + ' NVRs record this camera (' + ($rec -join ', ') + '). Moving it would cut the others off. Move it by hand on every NVR, or call the office') }
  $chs = @(Get-FsCamChannels $c)
  if ($chs.Count -gt 1) { return ('NOT moved: ' + $chs.Count + ' NVR channels record this camera (' + (Format-FsCamChannels $chs) + '). Only one channel would follow it, the others would lose its video. Move it by hand on every channel, or call the office') }
  # 2.2.15 (Codex 2.2.14 R1): checked last, so the reasons above (more than one NVR / channel) keep their own words
  $un = @(Get-FsCamUnreadNvrs $c)
  if ($un.Count) { return ('NOT moved: the camera channel list of NVR ' + ($un -join ', ') + ' could not be read, so it is not known which channels record this camera - moving it could cut their video. Run Fix this site again; if the list still cannot be read, check the NVR by hand') }
  return ''
}
# 2.2.14 (Codex 2.2.13 F2): the Hikvision official reset/import CHANGES the camera password, so every camera goes through the same
# dependency guard (Get-FsPwChangeBlock, with the per-channel rule) BEFORE it becomes a reset target. NVRs that need the reset are
# targets as before. $LiveCheck (optional): { param($nvrIp) 'ok' or the reason } = the one recorder must answer right now.
# Returns targets (mac, ip, kind) and blocked (cam, why): a blocked camera is not reset and stays a problem with its reason.
function Get-FsHikResetTargets($plan, $nvrCred, [scriptblock]$LiveCheck = $null) {
  $t = @(); $b = @()
  foreach ($n in @($plan.nvrs | Where-Object { @($_.steps) -contains 'reset' })) { $t += [pscustomobject]@{ mac = (ConvertTo-FsMac ([string]$n.mac)); ip = $n.ip; kind = 'nvr' } }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'fix' -and @($_.steps) -contains 'reset' -and $_.brand -eq 'Hikvision' })) {
    $recs = @(Get-FsCamRecorders $c)
    $why = [string](Get-FsPwChangeBlock $c $recs $nvrCred)
    if (-not $why -and $recs.Count -eq 1 -and $LiveCheck) { $st = [string](& $LiveCheck ([string]$recs[0])); if ($st -ne 'ok') { $why = 'password not changed: NVR ' + $recs[0] + ' records this camera and does not answer right now (' + $st + ') - it could not be updated and checked. Run Fix this site again when it is back' } }
    if ($why) { $b += [pscustomobject]@{ cam = $c; mac = (ConvertTo-FsMac ([string]$c.mac)); ip = $c.ip; why = ('official reset NOT run - ' + $why) }; continue }
    $t += [pscustomobject]@{ mac = (ConvertTo-FsMac ([string]$c.mac)); ip = $c.ip; kind = 'camera' }
  }
  return [pscustomobject]@{ targets = $t; blocked = $b }
}
# 2.2.13 (Codex 2.2.12 #1): may this camera's password be changed? '' = yes; otherwise the plain reason it is not.
# Only ONE recorder can be updated and checked by the tool (its main NVR channel); every recorder of the camera must be that one,
# with a known login. Whether it answers right now is checked by the caller (a live login).
function Get-FsPwChangeBlock($c, $recorders, $nvrCred) {
  $recs = @($recorders | Where-Object { $_ })
  if ($recs.Count -gt 1) { return ('password not changed: ' + $recs.Count + ' NVRs record this camera (' + ($recs -join ', ') + ', counting the NVR the site list names) - only one could be updated and checked, the others would lose its video. Change it on all of them by hand, or call the office') }
  if ($recs.Count -eq 1) {
    $r = [string]$recs[0]
    if (-not $nvrCred -or -not $nvrCred.ContainsKey($r)) { return ('password not changed: NVR ' + $r + ' records this camera and its login is unknown (or it did not answer) - it could not be updated and checked') }
    if ([string](Get-FsProp $c 'nvr' '') -ne $r -or @(Get-FsProp $c 'steps' @()) -notcontains 'nvr') { return ('password not changed: NVR ' + $r + ' records this camera but is not the one this run updates - change it by hand') }
  }
  # 2.2.14 (Codex 2.2.13 F1): one recorder, but more than one of its CHANNELS records the camera: only one channel is updated and
  # checked, the others would lose its video. Refused (the camera keeps its old password, Still a problem, nonzero exit).
  $chs = @(Get-FsCamChannels $c)
  if ($chs.Count -gt 1) { return ('password not changed: ' + $chs.Count + ' NVR channels record this camera (' + (Format-FsCamChannels $chs) + ') - only one channel could be updated and checked, the others would lose its video. Change it on every channel by hand, or call the office') }
  # 2.2.15 (Codex 2.2.14 R1): checked last, so the reasons above (more than one NVR / channel, unknown login) keep their own words
  $un = @(Get-FsCamUnreadNvrs $c)
  if ($un.Count) { return ('password not changed: the camera channel list of NVR ' + ($un -join ', ') + ' could not be read, so it is not known which channels record this camera - changing it could cut their video. Run Fix this site again; if the list still cannot be read, check the NVR by hand') }
  return ''
}
function Get-FsCamMatchKey($c) {
  # 2.2.12 (Codex 2.2.11 #12, F19): the same camera without a MAC: same serial on the same NVR channel; no serial either: the same NVR
  # channel at the same address. Nothing to go on = '' (never merged).
  $sr = ([string](Get-FsProp $c 'serial' '')).Trim().ToUpperInvariant(); $nv = ([string](Get-FsProp $c 'nvr' '')).Trim(); $ch = [int](Get-FsProp $c 'channel' 0); $ip = ([string](Get-FsProp $c 'ip' '')).Trim()
  if ($sr) { return ('s|' + $sr + '|' + $nv + '|' + $ch) }
  if ($nv -and $ch -gt 0 -and $ip) { return ('a|' + $nv + '|' + $ch + '|' + $ip) }
  return ''
}
function Merge-FsSiteListCams($oldCams, $newCams) {
  # 2.2.3 (Codex #38): adding cameras to a saved list also brings the ones already on it up to date (same MAC = same camera:
  # its address, channel, NVR as found now); cameras not seen this time keep their saved entry
  # 2.2.12 (F19): a camera with no MAC is matched by serial + NVR + channel (or NVR + channel + address with no serial), so running
  # it twice never adds it again. Two different MACs are never the same camera.
  $keep = @(); $new = @(@($newCams) | Where-Object { $_ }); $used = @{}
  foreach ($o in @($oldCams)) {
    if (-not $o) { continue }
    $om = ConvertTo-FsMac ([string](Get-FsProp $o 'mac' '')); $ok = Get-FsCamMatchKey $o; $hit = -1
    for ($i = 0; $i -lt $new.Count; $i++) {
      if ($used.ContainsKey($i)) { continue }
      $nm = ConvertTo-FsMac ([string](Get-FsProp $new[$i] 'mac' ''))
      if ($om -and $nm) { if ($om -eq $nm) { $hit = $i; break } else { continue } }
      if ($ok -and $ok -eq (Get-FsCamMatchKey $new[$i])) { $hit = $i; break }
    }
    if ($hit -ge 0) {
      $n = $new[$hit]; $used[$hit] = 1
      $e = [ordered]@{}; if ($o -is [Collections.IDictionary]) { foreach ($k in $o.Keys) { $e[$k] = $o[$k] } } else { foreach ($p in $o.PSObject.Properties) { $e[$p.Name] = $p.Value } }
      foreach ($k in @('ip', 'channel', 'nvr')) { $v = Get-FsProp $n $k $null; if ($v) { $e[$k] = $v } }
      if (-not $om) { $nm = ConvertTo-FsMac ([string](Get-FsProp $n 'mac' '')); if ($nm) { $e['mac'] = [string](Get-FsProp $n 'mac' '') } }
      $keep += $e
    } else { $keep += $o }
  }
  for ($i = 0; $i -lt $new.Count; $i++) { if (-not $used.ContainsKey($i)) { $keep += $new[$i] } }
  return $keep
}

# ---------------- 2.0.2: new site (no typing) ----------------
function New-FsNewSiteName([string]$gw, [datetime]$when = (Get-Date)) {
  # "New site 10.0.5.x 2026-11-04": what the scan sees (the router's network) + the day. The tech can give the address after the plan screen.
  $p3 = Get-FsP3 $gw
  return ('New site ' + $(if ($p3) { $p3 + '.x ' } else { '' }) + $when.ToString('yyyy-MM-dd'))
}
# 2.2.4 (Codex re-review of 2.2.3): EVERY site name gets a short fingerprint of its exact (trimmed, case-folded) text, so names that
# differ only in punctuation or spacing ("A B", "A_B", "A  B", "A/B") never share a password store, list file or hikreset state.
# Files written under the 2.2.2 name (no fingerprint) or the 2.2.3 name (6-hex fingerprint on punctuated names) are still read, but
# only when the file itself says it belongs to exactly this site name (Resolve-FsLocalList, Read-FsSecrets).
function Get-FsNameHash([string]$text, [int]$bytes = 4) {
  $sha = [Security.Cryptography.SHA256]::Create(); try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([string]$text).Trim().ToLowerInvariant())) } finally { $sha.Dispose() }
  return (-join ($h[0..($bytes - 1)] | ForEach-Object { $_.ToString('x2') }))
}
function Get-FsLegacySlug([string]$site) { return (($site -replace '[^A-Za-z0-9_-]+', '_').Trim('_')) }
function Get-FsSiteSlug([string]$site) {
  $b = (Get-FsLegacySlug $site).ToLowerInvariant(); if (-not $b) { $b = 'site' }; if ($b.Length -gt 60) { $b = $b.Substring(0, 60) }   # lower case: one file on any filesystem
  return ($b + '-' + (Get-FsNameHash $site 4))
}
function Get-FsOldSlugs([string]$site) {
  # the names 2.2.3 and 2.2.2 used for this site (read-only fallbacks, newest first)
  $out = @(); $b = Get-FsLegacySlug $site; $t = ([string]$site).Trim()
  if ($t -match '[^A-Za-z0-9_\- ]') { $out += ($b + '-' + (Get-FsNameHash $site 3)) }
  if ($b) { $out += $b }
  return @($out | Where-Object { $_ -and $_ -ne (Get-FsSiteSlug $site) })
}
function Test-FsSameSite([string]$a, [string]$b) { return (([string]$a).Trim() -eq ([string]$b).Trim()) }   # 2.2.4: spacing counts ("A  B" is not "A B"); case does not
function Get-FsListFileName([string]$site) { return ((Get-FsSiteSlug $site) + '.json') }
function Resolve-FsLocalList([string]$dir, [string]$site) {
  # the list file for exactly this site; a 2.2.2/2.2.3 file under an old name is used only when it says it is this site
  $p = Join-Path $dir (Get-FsListFileName $site); if (Test-Path -LiteralPath $p) { return $p }
  foreach ($old in @(Get-FsOldSlugs $site)) {
    $lp = Join-Path $dir ($old + '.json')
    if (Test-Path -LiteralPath $lp) { try { $l = Get-Content -LiteralPath $lp -Raw | ConvertFrom-Json; if (Test-FsSameSite ([string](Get-FsProp $l 'site' '')) $site) { return $lp } } catch {} }
  }
  return $p
}
function Get-FsKnownSiteFiles([string]$sitesDir, [string[]]$driveRoots = @()) {
  # every saved site list this PC can see: sites\*.json, and each Drive site folder's Docs\WireIt site list.json
  $out = @()
  if ($sitesDir -and (Test-Path -LiteralPath $sitesDir)) { $out += @(Get-ChildItem -LiteralPath $sitesDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
  foreach ($root in @($driveRoots)) {
    $r = [Environment]::ExpandEnvironmentVariables([string]$root); if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' })) { $lp = Join-Path (Join-Path $d.FullName 'Docs') 'WireIt site list.json'; if (Test-Path -LiteralPath $lp) { $out += $lp } }
  }
  return $out
}
function Find-FsKnownSite($paths, $found) {
  # a "New site" run at a site already saved (this PC's sites\ or a Drive site folder): the NVR's MAC, or 2+ camera MACs, match a saved list.
  # $paths: list files, or a folder of them. Returns { path; list; site; score } or $null.
  $files = @(); foreach ($p in @($paths)) { if (-not $p) { continue }; if (Test-Path -LiteralPath $p -PathType Container) { $files += @(Get-ChildItem -LiteralPath $p -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) } elseif (Test-Path -LiteralPath $p) { $files += [string]$p } }
  if (-not $files.Count) { return $null }
  $macs = @{}; foreach ($d in @($found)) { $m = ConvertTo-FsMac ([string](Get-FsProp $d 'mac' '')); if ($m) { $macs[$m] = [string](Get-FsProp $d 'kind' 'camera') } }
  if (-not $macs.Count) { return $null }
  $best = $null
  foreach ($fp in $files) {
    try { $l = Get-Content -LiteralPath $fp -Raw | ConvertFrom-Json } catch { continue }
    if (-not $l) { continue }
    $nvrHit = @(@(Get-FsProp $l 'nvrs' @()) | Where-Object { $m = ConvertTo-FsMac ([string](Get-FsProp $_ 'mac' '')); $m -and $macs.ContainsKey($m) }).Count
    $camHit = @(@(Get-FsProp $l 'cameras' @()) | Where-Object { $m = ConvertTo-FsMac ([string](Get-FsProp $_ 'mac' '')); $m -and $macs.ContainsKey($m) }).Count
    $score = 2 * $nvrHit + $camHit
    if ($score -ge 2 -and (-not $best -or $score -gt $best.score)) {
      $isDrive = ((Split-Path -Leaf $fp) -eq 'WireIt site list.json')
      $nm = $(if ($isDrive) { Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $fp)) } elseif ([string](Get-FsProp $l 'site' '')) { [string]$l.site } else { [IO.Path]::GetFileNameWithoutExtension($fp) })
      $best = [pscustomobject]@{ path = $fp; list = $l; site = $nm; score = $score; folder = $(if ($isDrive) { Split-Path -Parent (Split-Path -Parent $fp) } else { '' }) }
    }
  }
  return $best
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
  # 2.2.3 (Codex #40): a partial match counts only when it is the ONLY one (all Drive roots together), and a Site ID matches as a
  # whole word (WI-12 is not WI-123). Two or more = $null, and $script:FsSiteFolderAmbiguous names them, so nobody gets another site's list.
  $script:FsSiteFolderAmbiguous = @()
  if (-not $site) { return $null }; $s = $site.Trim()
  $all = @()
  foreach ($root in @($roots)) {
    $r = [Environment]::ExpandEnvironmentVariables([string]$root); if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
    $all += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' })
  }
  $f = @($all | Where-Object { $_.Name -eq $s }); if ($f.Count -ge 1) { return $f[0].FullName }
  $esc = [regex]::Escape($s)
  $pat = $(if ($s -match '^(?i)WI-\d+$') { '(?i)(^|[^A-Za-z0-9])' + $esc + '($|[^0-9])' } else { '(?i)' + $esc })
  $part = @($all | Where-Object { $_.Name -match $pat })
  if ($part.Count -eq 1) { return $part[0].FullName }
  if ($part.Count -gt 1) { $script:FsSiteFolderAmbiguous = @($part | ForEach-Object { $_.Name }); return $null }
  if ($s -match '^(?i)WI-\d+$') {
    $hit = @(); foreach ($d in $all) { $lp = Join-Path (Join-Path $d.FullName 'Docs') 'WireIt site list.json'; if (Test-Path -LiteralPath $lp) { try { $j = Get-Content -LiteralPath $lp -Raw | ConvertFrom-Json; if ([string]$j.siteId -eq $s) { $hit += $d } } catch {} } }
    if ($hit.Count -eq 1) { return $hit[0].FullName }
    if ($hit.Count -gt 1) { $script:FsSiteFolderAmbiguous = @($hit | ForEach-Object { $_.Name }) }
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
# 2.2.2 (re-review H8): where an NVR is NOW during an Undo. A run that moved the NVR recorded its new address (target); once an earlier
# Undo moved it back ('nvrmove|<ip>' done) it answers on its OLD address again, so a channel or password step retried by a second
# Undo goes there, not to the address it no longer has.
function Resolve-FsUndoNvrIp($RbNvrs, [string]$Addr, [scriptblock]$IsDone) {
  foreach ($n in @($RbNvrs)) {
    if (-not $n) { continue }
    if ([string]$n.target -eq $Addr -and (& $IsDone ('nvrmove|' + [string]$n.ip))) { return [string]$n.old.ip }
  }
  return $Addr
}
# 2.2.12 (Codex 2.2.11 #13, F20): what a site name may hold. Letters, digits, spaces and . , # & ( ) / _ - , 1 to 80 characters.
# No quotes, no $ ` ; | < > \ : the name goes on the command line of the blue (elevated) window, so nothing in it can end the
# quoted argument or start another one.
$script:FsSiteRe = '^[A-Za-z0-9][A-Za-z0-9 .,#&()/_-]{0,79}$'   # starts with a letter or digit (never a - that could look like a switch)
function Test-FsSiteName([string]$s) { return ([string]$s -cmatch $script:FsSiteRe -and ([string]$s).Length -le 80) }
function ConvertTo-FsCmdArg([string]$s) {
  # one double-quoted command-line argument; refuses (returns $null) anything the site-name rule does not allow
  if (-not (Test-FsSiteName $s)) { return $null }
  return ('"' + $s + '"')
}
function Get-FsExitWords([int]$code, [string]$mode = '') {
  if ($code -notin @(0, 2, 4, 6, 7) -and $mode -in @('Plan', 'DryRun')) { return ('It stopped unexpectedly (code ' + $code + '). Just look changes nothing on the cameras or NVRs. Run it again, or call the office.') }
  switch ($code) {
    0 { return 'Done. Everything is fixed.' }
    4 { return 'Done, but some things still need you: see the lines marked with a red X.' }
    2 { return 'Stopped. Nothing was changed.' }
    7 { return 'Stopped: the undo file could not be saved, so nothing more was changed (see the red line). What was already done is in the undo file.' }   # 2.2.6
    6 { return 'FAILED - Run again. THIS PC''s network could not be put back the way it was (see the red line). Press Fix this site again (it puts the network back first), or restart the PC.' }   # 2.2.2 (H4); 2.2.10 (Moshe Nov 9: an unverified restore says FAILED - Run again, never success)
    # 2.2.12 (Codex 2.2.11 #14): an unexpected stop can come after cameras or NVRs were already changed - never say nothing is half-done
    9 { return ('STOPPED HALF-WAY (code 9). Some cameras or NVRs may already have been changed. This PC''s network was put back. Press "Undo the last fix" to put this site back, or press Fix this site again, or call the office. The run folder has the log and the undo file.') }
    default { return ('STOPPED HALF-WAY (code ' + $code + '). Some cameras or NVRs may already have been changed. Press "Undo the last fix" to put this site back, or press Fix this site again (it puts this PC''s network back first), or call the office. The run folder has the log and the undo file.') }
  }
}
function Get-FsLastRun([string]$runsDir, [switch]$Undoable) {
  if (-not (Test-Path -LiteralPath $runsDir)) { return $null }
  foreach ($d in @(Get-ChildItem -LiteralPath $runsDir -Directory -Filter 'FixSite-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
    if ($Undoable) { if ((Test-Path (Join-Path $d.FullName 'rollback.json')) -and -not (Test-Path (Join-Path $d.FullName 'undone.txt'))) { return $d } } else { return $d }
  }
  return $null
}
