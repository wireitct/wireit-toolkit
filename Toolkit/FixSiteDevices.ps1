<#
 FixSiteDevices.ps1 - WireIt Toolkit 2.0 "Fix this site": talking to cameras, NVRs, this PC and the site's secret store.
 Official interfaces only: Hikvision ISAPI, Dahua HTTP API (CGI), Hikvision SADP / Dahua search (read-only discovery).
 No exploits, no password guessing: a login is tried only with the site's own saved passwords (a short, fixed list).
 Passwords are never written to a log or a file in plain text. Dot-sourced by FixSite.ps1 (and the tests).
 Test harness: $script:FsMockUrl = 'http://127.0.0.1:<port>' sends every device call to the mock server (tests\fixsite\mock_site.py).
#>
$script:FsMockUrl = ''
$script:FsIsPs5 = $PSVersionTable.PSVersion.Major -lt 6
$script:FsTestSecrets = $false
if ($script:FsIsPs5) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; [Net.ServicePointManager]::Expect100Continue = $false } catch {}
}
function Fs-LogLine([string]$s) { if (Get-Command Fs-Log -ErrorAction SilentlyContinue) { Fs-Log $s } }

# ---------------- HTTP (digest/basic handled by .NET; passwords never logged) ----------------
function Fs-Cred([string]$pw, [string]$user = 'admin') { if (-not $pw) { return $null }; return New-Object PSCredential($user, (ConvertTo-SecureString $pw -AsPlainText -Force)) }
function Fs-Plain($cred) { if (-not $cred) { return '' }; return $cred.GetNetworkCredential().Password }
function Fs-Xml([string]$s) { return [Security.SecurityElement]::Escape([string]$s) }
function Fs-Http {
  param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = 'application/xml', $Cred = $null, [int]$Timeout = 8, [string]$OutFile = '', [switch]$Secret)
  $base = $(if ($script:FsMockUrl) { $script:FsMockUrl.TrimEnd('/') + '/dev/' + $Ip } else { 'http://' + $Ip })
  $a = @{ Uri = ($base + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = $Timeout; ErrorAction = 'Stop' }
  if ($Cred) { $a.Credential = $Cred; if (-not $script:FsIsPs5) { $a.AllowUnencryptedAuthentication = $true } }
  if ($Body) { $a.Body = [Text.Encoding]::UTF8.GetBytes($Body); $a.ContentType = $ContentType }
  if ($OutFile) { $a.OutFile = $OutFile }
  $shown = $(if ($Secret) { ($Path -replace '\?.*$', '?(hidden)') } else { $Path })
  Fs-LogLine ($Method + ' ' + $Ip + $shown + $(if ($Body -and -not $Secret) { ' BODY ' + $(if ($Body.Length -gt 300) { $Body.Substring(0, 300) + '...' } else { $Body }) } elseif ($Body) { ' BODY (hidden)' } else { '' }))
  try {
    $r = Invoke-WebRequest @a
    $c = ''; if (-not $OutFile) { $c = [string]$r.Content; if ($r.Content -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($r.Content) } }
    $code = 200; if ($r -and $r.StatusCode) { $code = [int]$r.StatusCode }
    Fs-LogLine ('  -> ' + $code + $(if ($c -and -not $Secret) { ' ' + $(if ($c.Length -gt 200) { $c.Substring(0, 200) + '...' } else { $c }) } else { '' }))
    return [pscustomobject]@{ code = $code; body = $c }
  } catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    $eb = ''; try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $eb = [string]$_.ErrorDetails.Message } } catch {}
    Fs-LogLine ('  -> ' + $code + ' ' + $_.Exception.Message)
    return [pscustomobject]@{ code = $code; body = $eb }
  }
}
function Fs-XmlDoc([string]$s) { if (-not $s) { return $null }; try { [xml]$x = $s; return $x } catch { return $null } }
function Fs-XFind($node, [string]$name) { if (-not $node) { return @() }; return @($node.SelectNodes(".//*[local-name()='" + $name + "']")) }
function Fs-XText($node, [string]$name) { $n = @(Fs-XFind $node $name); if ($n.Count -and $n[0]) { return ([string]$n[0].InnerText).Trim() }; return '' }
function Fs-XSet($node, [string]$name, [string]$v) { $n = @(Fs-XFind $node $name); if ($n.Count -and $n[0]) { $n[0].InnerText = $v; return $true }; return $false }
function Fs-HikOk($r) { if (-not $r -or $r.code -ne 200) { return $false }; $x = Fs-XmlDoc $r.body; if (-not $x) { return $true }; $sc = Fs-XText $x 'statusCode'; return (-not $sc -or $sc -eq '1' -or $sc -eq '7') }
function Fs-HikNeedsReboot($r) { $x = Fs-XmlDoc $r.body; return ((Fs-XText $x 'statusCode') -eq '7') }
function Fs-DhLines([string]$body) {
  # Dahua answers "table.Network.eth0.IPAddress=192.168.1.83" lines -> hashtable without the "table." prefix
  $h = @{}; foreach ($l in ($body -split "`r?`n")) { $m = [regex]::Match($l, '^(?:table\.)?([^=]+)=(.*)$'); if ($m.Success) { $h[$m.Groups[1].Value.Trim()] = $m.Groups[2].Value.Trim() } }; return $h
}
function Fs-DhSet([string]$ip, $cred, [hashtable]$kv) {
  $q = @(); foreach ($k in $kv.Keys) { $q += ([uri]::EscapeDataString([string]$k).Replace('%5B', '[').Replace('%5D', ']') + '=' + [uri]::EscapeDataString([string]$kv[$k])) }
  $r = Fs-Http -Ip $ip -Path ('/cgi-bin/configManager.cgi?action=setConfig&' + ($q -join '&')) -Cred $cred
  return ($r.code -eq 200 -and $r.body -match '(?i)^\s*OK')
}

# ---------------- login (one try per known password; stops at "locked") ----------------
function Test-FsLogin([string]$ip, [string]$brand, [string]$pw) {
  # 'ok' | 'refused' | 'locked' | 'noanswer' | 'notfound'
  $cred = Fs-Cred $pw
  if ($brand -eq 'Dahua') {
    $r = Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getDeviceType' -Cred $cred -Timeout 6
    if ($r.code -eq 200) { return 'ok' }; if ($r.code -eq 401) { if ($r.body -match '(?i)lock') { return 'locked' }; return 'refused' }; if ($r.code -eq 404) { return 'notfound' }; return 'noanswer'
  }
  $r = Fs-Http -Ip $ip -Path '/ISAPI/System/deviceInfo' -Cred $cred -Timeout 6
  if ($r.code -eq 200) { return 'ok' }
  if ($r.code -eq 401 -or $r.code -eq 403) { if ($r.body -match '(?i)lock|unlockTime') { return 'locked' }; return 'refused' }
  if ($r.code -eq 404 -and $brand -ne 'Hikvision') { return (Test-FsLogin $ip 'Dahua' $pw) }
  return 'noanswer'
}
function Find-FsPassword([string]$ip, [string]$brand, $candidates, [int]$maxTries = 3) {
  # tries the site's own passwords in order, never more than $maxTries, stops at a lock. Returns { state; label; value; tries }
  $n = 0; $last = 'unknown'
  foreach ($c in @($candidates)) {
    if ($n -ge $maxTries) { break }; $n++
    $s = Test-FsLogin $ip $brand $c.value
    if ($s -eq 'ok') { return [pscustomobject]@{ state = 'ok'; label = $c.label; value = $c.value; tries = $n } }
    if ($s -eq 'locked') { return [pscustomobject]@{ state = 'locked'; label = ''; value = ''; tries = $n } }
    if ($s -eq 'noanswer' -or $s -eq 'notfound') { return [pscustomobject]@{ state = 'noanswer'; label = ''; value = ''; tries = $n } }
    $last = 'unknown'
  }
  return [pscustomobject]@{ state = $last; label = ''; value = ''; tries = $n }
}

# ---------------- device info / backup ----------------
function Get-FsInfo([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') {
    $t = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getSystemInfo' -Cred $cred).body
    $v = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getSoftwareVersion' -Cred $cred).body
    return [pscustomobject]@{ brand = 'Dahua'; model = [string]$t['deviceType']; serial = [string]$t['serialNumber']; firmware = [string]$v['version'] }
  }
  $x = Fs-XmlDoc (Fs-Http -Ip $ip -Path '/ISAPI/System/deviceInfo' -Cred $cred).body
  return [pscustomobject]@{ brand = 'Hikvision'; model = (Fs-XText $x 'model'); serial = (Fs-XText $x 'serialNumber'); mac = (Fs-XText $x 'macAddress'); firmware = ((Fs-XText $x 'firmwareVersion') + ' ' + (Fs-XText $x 'firmwareReleasedDate')).Trim() }
}
function Save-FsBackup([string]$ip, [string]$brand, $cred, [string]$dir) {
  # the camera's own config export (its import format) + readable network / video settings. Stays on this PC (run folder).
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $files = @()
  if ($brand -eq 'Dahua') {
    $f = Join-Path $dir 'config-export.backup'; $r = Fs-Http -Ip $ip -Path '/cgi-bin/Config.backup?action=All' -Cred $cred -OutFile $f -Timeout 20
    if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { $files += $f } else { Remove-Item $f -ErrorAction SilentlyContinue }
    foreach ($n in @('Network', 'Encode', 'SmartEncode', 'NTP')) { $r = Fs-Http -Ip $ip -Path ('/cgi-bin/configManager.cgi?action=getConfig&name=' + $n) -Cred $cred; if ($r.code -eq 200) { $p = Join-Path $dir ($n + '.txt'); [IO.File]::WriteAllText($p, $r.body); $files += $p } }
  } else {
    $f = Join-Path $dir 'configurationData.bin'; $r = Fs-Http -Ip $ip -Path '/ISAPI/System/configurationData' -Cred $cred -OutFile $f -Timeout 30
    if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { $files += $f } else { Remove-Item $f -ErrorAction SilentlyContinue }
    foreach ($pp in @(@('network.xml', '/ISAPI/System/Network/interfaces'), @('stream-101.xml', '/ISAPI/Streaming/channels/101'), @('stream-102.xml', '/ISAPI/Streaming/channels/102'), @('time.xml', '/ISAPI/System/time'))) {
      $r = Fs-Http -Ip $ip -Path $pp[1] -Cred $cred; if ($r.code -eq 200) { $p = Join-Path $dir $pp[0]; [IO.File]::WriteAllText($p, $r.body); $files += $p }
    }
  }
  return $files
}

# ---------------- network ----------------
function Get-FsNet([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') {
    $h = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=Network' -Cred $cred).body
    $if = [string]$h['Network.DefaultInterface']; if (-not $if) { $if = 'eth0' }
    $pre = 'Network.' + $if + '.'
    return [pscustomobject]@{ iface = $if; ip = [string]$h[$pre + 'IPAddress']; mask = [string]$h[$pre + 'SubnetMask']; gw = [string]$h[$pre + 'DefaultGateway']; dhcp = ([string]$h[$pre + 'DhcpEnable'] -eq 'true'); dns1 = [string]$h[$pre + 'DnsServers[0]']; dns2 = [string]$h[$pre + 'DnsServers[1]']; raw = $null }
  }
  $li = Fs-XmlDoc (Fs-Http -Ip $ip -Path '/ISAPI/System/Network/interfaces' -Cred $cred).body
  $id = Fs-XText $li 'id'; if (-not $id) { $id = '1' }
  $r = Fs-Http -Ip $ip -Path ('/ISAPI/System/Network/interfaces/' + $id + '/ipAddress') -Cred $cred
  $x = Fs-XmlDoc $r.body; if (-not $x) { return $null }
  $gwn = @(Fs-XFind $x 'DefaultGateway'); $gw = ''; if ($gwn.Count) { $gw = Fs-XText $gwn[0] 'ipAddress' }
  $d1 = @(Fs-XFind $x 'PrimaryDNS'); $d2 = @(Fs-XFind $x 'SecondaryDNS')
  return [pscustomobject]@{ iface = $id; ip = (Fs-XText $x 'ipAddress'); mask = (Fs-XText $x 'subnetMask'); gw = $gw; dhcp = ((Fs-XText $x 'addressingType') -eq 'dynamic'); dns1 = $(if ($d1.Count) { Fs-XText $d1[0] 'ipAddress' } else { '' }); dns2 = $(if ($d2.Count) { Fs-XText $d2[0] 'ipAddress' } else { '' }); raw = $r.body }
}
function Set-FsNet([string]$ip, [string]$brand, $cred, $net, [string]$newIp, [string]$mask, [string]$gw, [string]$dns1 = '8.8.8.8', [string]$dns2 = '1.1.1.1') {
  # returns { ok; reboot } . The device answers on the NEW address afterwards (or after its own restart).
  if ($brand -eq 'Dahua') {
    $pre = 'Network.' + $net.iface + '.'
    $ok = Fs-DhSet $ip $cred @{ ($pre + 'IPAddress') = $newIp; ($pre + 'SubnetMask') = $mask; ($pre + 'DefaultGateway') = $gw; ($pre + 'DhcpEnable') = 'false'; ($pre + 'DnsServers[0]') = $dns1; ($pre + 'DnsServers[1]') = $dns2 }
    return [pscustomobject]@{ ok = $ok; reboot = $false }
  }
  $x = Fs-XmlDoc $net.raw; if (-not $x) { return [pscustomobject]@{ ok = $false; reboot = $false } }
  [void](Fs-XSet $x 'addressingType' 'static')
  $top = @(Fs-XFind $x 'IPAddress')[0]
  foreach ($n in @($top.ChildNodes)) { if ($n.LocalName -eq 'ipAddress') { $n.InnerText = $newIp }; if ($n.LocalName -eq 'subnetMask') { $n.InnerText = $mask } }
  $g = @(Fs-XFind $x 'DefaultGateway'); if ($g.Count) { [void](Fs-XSet $g[0] 'ipAddress' $gw) }
  $d = @(Fs-XFind $x 'PrimaryDNS'); if ($d.Count) { [void](Fs-XSet $d[0] 'ipAddress' $dns1) }
  $d = @(Fs-XFind $x 'SecondaryDNS'); if ($d.Count) { [void](Fs-XSet $d[0] 'ipAddress' $dns2) }
  $r = Fs-Http -Ip $ip -Method 'PUT' -Path ('/ISAPI/System/Network/interfaces/' + $net.iface + '/ipAddress') -Body $x.OuterXml -Cred $cred
  return [pscustomobject]@{ ok = (Fs-HikOk $r); reboot = (Fs-HikNeedsReboot $r) }
}

# ---------------- password ----------------
function Set-FsPassword([string]$ip, [string]$brand, $oldCred, [string]$newPw) {
  if ($brand -eq 'Dahua') {
    $r = Fs-Http -Ip $ip -Path ('/cgi-bin/userManager.cgi?action=modifyPassword&name=admin&pwd=' + [uri]::EscapeDataString($newPw) + '&pwdOld=' + [uri]::EscapeDataString((Fs-Plain $oldCred))) -Cred $oldCred -Secret
    return ($r.code -eq 200 -and $r.body -match '(?i)OK')
  }
  $xml = '<?xml version="1.0" encoding="UTF-8"?><User version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>1</id><userName>admin</userName><password>' + (Fs-Xml $newPw) + '</password><loginPassword>' + (Fs-Xml (Fs-Plain $oldCred)) + '</loginPassword></User>'
  $r = Fs-Http -Ip $ip -Method 'PUT' -Path '/ISAPI/Security/users/1' -Body $xml -Cred $oldCred -Secret
  return (Fs-HikOk $r)
}

# ---------------- video settings (main stream) ----------------
function Get-FsStream([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') {
    $h = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=Encode' -Cred $cred).body
    if (-not $h.Count) { return $null }
    $p = 'Encode[0].MainFormat[0].Video.'
    $sc = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=SmartEncode' -Cred $cred).body
    $scv = ''; foreach ($k in $sc.Keys) { if ($k -match 'SmartEncode\[0\]\.Enable$') { $scv = $(if ($sc[$k] -eq 'true') { 'on' } else { 'off' }) } }
    return [pscustomobject]@{ codec = ([string]$h[$p + 'Compression'] -replace 'H\.?26', 'H.26'); fps = [int][double]$h[$p + 'FPS']; width = [int]$h[$p + 'Width']; height = [int]$h[$p + 'Height']; bitrate = [int]$h[$p + 'BitRate']; gop = [int]$h[$p + 'GOP']; smartCodec = $scv; maxWidth = 0; maxHeight = 0; raw = $null }
  }
  $r = Fs-Http -Ip $ip -Path '/ISAPI/Streaming/channels/101' -Cred $cred; $x = Fs-XmlDoc $r.body; if (-not $x) { return $null }
  $q = Fs-XText $x 'videoQualityControlType'; $br = $(if ($q -eq 'VBR') { Fs-XText $x 'vbrUpperCap' } else { Fs-XText $x 'constantBitRate' })
  $scn = @(Fs-XFind $x 'SmartCodec'); $sc = ''; if ($scn.Count) { $sc = $(if ((Fs-XText $scn[0] 'enabled') -eq 'true') { 'on' } else { 'off' }) }
  $mw = 0; $mh = 0
  $cap = Fs-XmlDoc (Fs-Http -Ip $ip -Path '/ISAPI/Streaming/channels/101/capabilities' -Cred $cred).body
  if ($cap) { $wn = @(Fs-XFind $cap 'videoResolutionWidth'); if ($wn.Count -and $wn[0].opt) { $mw = [int](@($wn[0].opt -split ',' | ForEach-Object { [int]$_ } | Sort-Object -Descending)[0]) }; $hn = @(Fs-XFind $cap 'videoResolutionHeight'); if ($hn.Count -and $hn[0].opt) { $mh = [int](@($hn[0].opt -split ',' | ForEach-Object { [int]$_ } | Sort-Object -Descending)[0]) } }
  return [pscustomobject]@{ codec = ((Fs-XText $x 'videoCodecType') -replace '^H\.?26', 'H.26'); fps = [int]([int](Fs-XText $x 'maxFrameRate') / 100); width = [int](Fs-XText $x 'videoResolutionWidth'); height = [int](Fs-XText $x 'videoResolutionHeight'); bitrate = [int]$br; gop = [int](Fs-XText $x 'GovLength'); smartCodec = $sc; maxWidth = $mw; maxHeight = $mh; raw = $r.body }
}
function Set-FsStream([string]$ip, [string]$brand, $cred, $current, $diff) {
  # applies ONLY the fields in $diff (from Get-FsSettingsDiff). Returns { ok; reboot }
  if (-not @($diff).Count) { return [pscustomobject]@{ ok = $true; reboot = $false } }
  if ($brand -eq 'Dahua') {
    $p = 'Encode[0].MainFormat[0].Video.'; $kv = @{}; $smart = $null
    foreach ($d in @($diff)) {
      switch ($d.field) {
        'codec' { $kv[$p + 'Compression'] = [string]$d.to; if ([string]$d.to -eq 'H.264') { $kv[$p + 'Profile'] = 'Main' } }
        'fps' { $kv[$p + 'FPS'] = [string]$d.to } 'bitrate' { $kv[$p + 'BitRate'] = [string]$d.to } 'gop' { $kv[$p + 'GOP'] = [string]$d.to }
        'resolution' { $wh = ([string]$d.to) -split 'x'; $kv[$p + 'Width'] = $wh[0]; $kv[$p + 'Height'] = $wh[1] }
        'smartCodec' { $smart = 'false' }
      }
    }
    $ok = $true
    if ($smart) { $ok = (Fs-DhSet $ip $cred @{ 'SmartEncode[0].Enable' = $smart }) -and $ok }
    if ($kv.Count) { $ok = (Fs-DhSet $ip $cred $kv) -and $ok }
    return [pscustomobject]@{ ok = $ok; reboot = $false }
  }
  $x = Fs-XmlDoc $current.raw; if (-not $x) { return [pscustomobject]@{ ok = $false; reboot = $false } }
  foreach ($d in @($diff)) {
    switch ($d.field) {
      'codec' { [void](Fs-XSet $x 'videoCodecType' ([string]$d.to)) }
      'fps' { [void](Fs-XSet $x 'maxFrameRate' ([string]([int]$d.to * 100))) }
      'gop' { [void](Fs-XSet $x 'GovLength' ([string]$d.to)) }
      'bitrate' { if ((Fs-XText $x 'videoQualityControlType') -eq 'VBR') { [void](Fs-XSet $x 'vbrUpperCap' ([string]$d.to)) } else { [void](Fs-XSet $x 'constantBitRate' ([string]$d.to)) } }
      'resolution' { $wh = ([string]$d.to) -split 'x'; [void](Fs-XSet $x 'videoResolutionWidth' $wh[0]); [void](Fs-XSet $x 'videoResolutionHeight' $wh[1]) }
      'smartCodec' { $n = @(Fs-XFind $x 'SmartCodec'); if ($n.Count) { [void](Fs-XSet $n[0] 'enabled' 'false') } }
    }
  }
  $r = Fs-Http -Ip $ip -Method 'PUT' -Path '/ISAPI/Streaming/channels/101' -Body $x.OuterXml -Cred $cred
  return [pscustomobject]@{ ok = (Fs-HikOk $r); reboot = (Fs-HikNeedsReboot $r) }
}

function Restart-FsDevice([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') { $r = Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=reboot' -Cred $cred; return ($r.code -eq 200) }
  $r = Fs-Http -Ip $ip -Method 'PUT' -Path '/ISAPI/System/reboot' -Cred $cred; return (Fs-HikOk $r)
}
function Test-FsPicture([string]$ip, [string]$path, $cred) {
  # a real JPEG back = video is there
  $f = Join-Path ([IO.Path]::GetTempPath()) ('fs-pic-' + [guid]::NewGuid().ToString('N') + '.jpg')
  try {
    $r = Fs-Http -Ip $ip -Path $path -Cred $cred -OutFile $f -Timeout 12
    if (-not (Test-Path $f)) { return $false }
    $b = [IO.File]::ReadAllBytes($f); return ($b.Length -gt 1500 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8)
  } catch { return $false } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# ---------------- Hikvision NVR ----------------
function Get-FsNvrChannels([string]$nvrIp, $cred) {
  $r = Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Cred $cred
  $x = Fs-XmlDoc $r.body; if (-not $x) { return $null }
  $st = Fs-XmlDoc (Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels/status' -Cred $cred).body
  $on = @{}; foreach ($s in (Fs-XFind $st 'InputProxyChannelStatus')) { $on[[int](Fs-XText $s 'id')] = ((Fs-XText $s 'online') -eq 'true') }
  $out = @()
  foreach ($c in (Fs-XFind $x 'InputProxyChannel')) {
    $id = [int](Fs-XText $c 'id')
    $out += [pscustomobject]@{ channel = $id; name = (Fs-XText $c 'name'); ip = (Fs-XText $c 'ipAddress'); port = (Fs-XText $c 'managePortNo'); protocol = (Fs-XText $c 'proxyProtocol'); online = $(if ($on.ContainsKey($id)) { $on[$id] } else { $null }) }
  }
  return $out
}
function Set-FsNvrChannel([string]$nvrIp, $nvrCred, [int]$ch, [string]$camIp, [string]$camPw, [string]$camBrand, [string]$backupDir = '') {
  # puts the camera on that channel with its new address + the site password. Updates the channel when it exists, adds it when not.
  # returns { ok; action ('updated'|'added'|'failed'); before (xml, no password: the NVR never returns it) }
  $r = Fs-Http -Ip $nvrIp -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Cred $nvrCred
  $proto = $(if ($camBrand -eq 'Hikvision') { 'HIKVISION' } else { 'ONVIF' }); $port = $(if ($proto -eq 'HIKVISION') { '8000' } else { '80' })
  if ($r.code -eq 200 -and ($x = Fs-XmlDoc $r.body)) {
    if ($backupDir) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null; [IO.File]::WriteAllText((Join-Path $backupDir ('nvr-' + $nvrIp + '-ch' + $ch + '.xml')), $r.body) }
    $before = $r.body
    $cur = Fs-XText $x 'proxyProtocol'; if ($cur) { $proto = $cur; $port = Fs-XText $x 'managePortNo' }
    [void](Fs-XSet $x 'ipAddress' $camIp); [void](Fs-XSet $x 'userName' 'admin')
    if (-not (Fs-XSet $x 'password' $camPw)) {
      $sd = @(Fs-XFind $x 'sourceInputPortDescriptor')[0]; if ($sd) { $e = $x.CreateElement('password', $sd.NamespaceURI); $e.InnerText = $camPw; [void]$sd.AppendChild($e) }
    }
    $w = Fs-Http -Ip $nvrIp -Method 'PUT' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Body $x.OuterXml -Cred $nvrCred -Secret
    return [pscustomobject]@{ ok = (Fs-HikOk $w); action = 'updated'; before = $before; protocol = $proto }
  }
  $xml = '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>' + $ch + '</id><sourceInputPortDescriptor><proxyProtocol>' + $proto + '</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType><ipAddress>' + $camIp + '</ipAddress><managePortNo>' + $port + '</managePortNo><srcInputPort>1</srcInputPort><userName>admin</userName><password>' + (Fs-Xml $camPw) + '</password><streamType>auto</streamType></sourceInputPortDescriptor></InputProxyChannel>'
  $w = Fs-Http -Ip $nvrIp -Method 'POST' -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Body $xml -Cred $nvrCred -Secret
  return [pscustomobject]@{ ok = (Fs-HikOk $w); action = 'added'; before = ''; protocol = $proto }
}
function Test-FsVideo([string]$nvrIp, $nvrCred, [int]$ch, [string]$camIp, [string]$camBrand, $camCred) {
  # video is back = NVR says the channel is online AND hands out a picture of it (or, with no NVR, the camera itself does)
  if ($nvrIp -and $ch -gt 0) {
    $chs = @(Get-FsNvrChannels $nvrIp $nvrCred); $c = $chs | Where-Object { $_.channel -eq $ch } | Select-Object -First 1
    if (-not $c -or $c.online -ne $true) { return $false }
    return (Test-FsPicture $nvrIp ('/ISAPI/Streaming/channels/' + $ch + '01/picture') $nvrCred)
  }
  if ($camBrand -eq 'Dahua') { return (Test-FsPicture $camIp '/cgi-bin/snapshot.cgi?channel=1' $camCred) }
  return (Test-FsPicture $camIp '/ISAPI/Streaming/channels/101/picture' $camCred)
}

# ---------------- this PC: a temporary extra address to reach a camera on the wrong scheme ----------------
$script:FsTemps = New-Object System.Collections.ArrayList
function Get-FsPcNet {
  if ($script:FsMockUrl) { $r = Fs-Http -Ip '_pc' -Path '/net'; return ($r.body | ConvertFrom-Json) }
  $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
       Where-Object { $ad = Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue; $ad -and $ad.Status -eq 'Up' -and $ad.InterfaceDescription -notmatch 'Tailscale|WireGuard|TAP|VPN|Cellular|Mobile Broadband|Hyper-V' } | Select-Object -First 1
  if (-not $r) { return $null }
  $a = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.SkipAsSource -ne $true -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
  $dh = (Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Enabled'
  return [pscustomobject]@{ ip = $a.IPAddress; prefix = $a.PrefixLength; mask = '255.255.255.0'; gw = $r.NextHop; ifIndex = $r.ifIndex; dhcp = $dh }
}
function Test-FsIpFree([string]$ip) {
  if ($script:FsMockUrl) { $r = Fs-Http -Ip '_pc' -Path ('/free?ip=' + $ip); return ($r.body -match 'true') }
  try { if ((New-Object Net.NetworkInformation.Ping).Send($ip, 700).Status -eq 'Success') { return $false } } catch {}
  $n = Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.State -in @('Reachable', 'Stale', 'Permanent') -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' }
  return (-not $n)
}
function Add-FsTempIp([string]$p3, $pc, [string]$stateFile) {
  # memory-only (ActiveStore) extra address on the old scheme; never used as a source for normal traffic; removed at the end
  foreach ($t in $script:FsTemps) { if ($t.p3 -eq $p3) { return $t.ip } }
  if ($script:FsMockUrl) { $r = Fs-Http -Ip '_pc' -Path ('/addtemp?p3=' + $p3); $ip = $p3 + '.253'; [void]$script:FsTemps.Add([pscustomobject]@{ p3 = $p3; ip = $ip; ifIndex = 0 }); return $ip }
  foreach ($h in @(253, 252, 247, 246, 245)) {
    $ip = $p3 + '.' + $h; if (-not (Test-FsIpFree $ip)) { continue }
    try {
      New-NetIPAddress -InterfaceIndex $pc.ifIndex -IPAddress $ip -PrefixLength 24 -SkipAsSource $true -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
      [void]$script:FsTemps.Add([pscustomobject]@{ p3 = $p3; ip = $ip; ifIndex = $pc.ifIndex })
      if ($stateFile) { ($script:FsTemps | ConvertTo-Json -Depth 3) | Set-Content -Path $stateFile -Encoding UTF8 }
      Start-Sleep -Seconds 2
      return $ip
    } catch { Fs-LogLine ('temp IP ' + $ip + ' failed: ' + $_.Exception.Message) }
  }
  return ''
}
function Remove-FsTempIps([string]$stateFile) {
  foreach ($t in @($script:FsTemps)) {
    if ($script:FsMockUrl) { [void](Fs-Http -Ip '_pc' -Path ('/deltemp?p3=' + $t.p3)); continue }
    try { Remove-NetIPAddress -IPAddress $t.ip -InterfaceIndex $t.ifIndex -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop } catch {}
  }
  $script:FsTemps.Clear()
  if ($stateFile -and (Test-Path $stateFile)) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
}
function Clear-FsLeftoverTemps([string]$stateFile) {
  # a crashed run left a temporary address behind: remove it at the next start
  if ($script:FsMockUrl -or -not $stateFile -or -not (Test-Path $stateFile)) { return }
  try { $tj = Get-Content $stateFile -Raw | ConvertFrom-Json; foreach ($t in @($tj)) { try { Remove-NetIPAddress -IPAddress $t.ip -InterfaceIndex $t.ifIndex -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop } catch {} } } catch {}
  Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
}
function Wait-FsDevice([string]$ip, [string]$brand, [string]$pw, [int]$seconds) {
  $end = (Get-Date).AddSeconds($seconds)
  do { $s = Test-FsLogin $ip $brand $pw; if ($s -eq 'ok') { return $true }; if ($s -eq 'refused' -or $s -eq 'locked') { return $false }; Fs-Sleep 5 } while ((Get-Date) -lt $end)
  return $false
}
function Fs-Sleep([int]$s) { if ($script:FsMockUrl) { Start-Sleep -Milliseconds ([math]::Min(200, $s * 20)) } else { Start-Sleep -Seconds $s } }

# ---------------- PoE power-cycle through the office Dell's UniFi path (C:\WireIt\PortMap\camreboot.py --cycle) ----------------
function Invoke-FsPoeCycle([string]$siteId, [string]$mac, [string]$portMapDir) {
  # returns { state ('done'|'failed'|'refused'|'unavailable'); msg }
  if ($script:FsMockUrl) { $r = Fs-Http -Ip '_pc' -Path ('/poe?mac=' + $mac); return ($r.body | ConvertFrom-Json) }
  $py = $null; foreach ($p in @((Join-Path (Split-Path -Parent $portMapDir) 'VendorMonitor\python\python.exe'), (Join-Path $portMapDir 'python\python.exe'))) { if (Test-Path $p) { $py = $p; break } }
  $cr = Join-Path $portMapDir 'camreboot.py'
  if (-not $siteId -or -not $py -or -not (Test-Path $cr) -or -not (Select-String -Path $cr -Pattern '--cycle' -SimpleMatch -Quiet)) { return [pscustomobject]@{ state = 'unavailable'; msg = 'switch power-cycle is only on the office Dell (PortMap)' } }
  $out = & $py $cr '--cycle' $siteId $mac 2>&1 | Out-String
  $last = @($out -split "`r?`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
  if ($last.Count) { try { return ($last[0] | ConvertFrom-Json) } catch {} }
  return [pscustomobject]@{ state = 'failed'; msg = ('no answer from the switch job: ' + ($out.Trim() -replace '\s+', ' ')).Substring(0, [math]::Min(160, $out.Length + 30)) }
}

# ---------------- the site's secret store (encrypted for THIS Windows user on THIS PC; never Drive, never logs) ----------------
function Protect-FsText([string]$s) {
  if ($script:FsTestSecrets) { return ('TEST:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))) }
  Add-Type -AssemblyName System.Security
  return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($s), [Text.Encoding]::UTF8.GetBytes('WireIt-FixSite'), 'CurrentUser'))
}
function Unprotect-FsText([string]$s) {
  if ($s.StartsWith('TEST:')) { if (-not $script:FsTestSecrets) { throw 'test secret file on a real run' }; return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s.Substring(5))) }
  Add-Type -AssemblyName System.Security
  return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($s), [Text.Encoding]::UTF8.GetBytes('WireIt-FixSite'), 'CurrentUser'))
}
function Get-FsSecretPath([string]$dir, [string]$site) { return (Join-Path $dir ('site-' + (($site -replace '[^A-Za-z0-9_-]+', '_').Trim('_')) + '.dat')) }
function Read-FsSecrets([string]$dir, [string]$site) {
  $o = [ordered]@{ site = $site; password = ''; known = @(); usual = @(); nvr = @{}; rollback = @{}; bitwardenSaved = $false }
  $p = Get-FsSecretPath $dir $site
  if (Test-Path $p) { try { $j = (Unprotect-FsText ((Get-Content $p -Raw).Trim())) | ConvertFrom-Json; foreach ($k in @('password', 'known', 'bitwardenSaved')) { if ($j.PSObject.Properties[$k]) { $o[$k] = $j.$k } }; foreach ($k in @('nvr', 'rollback')) { if ($j.PSObject.Properties[$k] -and $j.$k) { $h = @{}; foreach ($q in $j.$k.PSObject.Properties) { $h[$q.Name] = $q.Value }; $o[$k] = $h } } } catch { Fs-LogLine ('secret store unreadable: ' + $_.Exception.Message) } }
  $u = Join-Path $dir 'wireit-usual.dat'
  if (Test-Path $u) { try { $uj = (Unprotect-FsText ((Get-Content $u -Raw).Trim())) | ConvertFrom-Json; $o.usual = @($uj) } catch {} }
  $o.known = @($o.known | Where-Object { $_ }); return [pscustomobject]$o
}
function Save-FsSecrets([string]$dir, $sec) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $keep = [ordered]@{ site = $sec.site; password = $sec.password; known = @($sec.known); nvr = $sec.nvr; rollback = $sec.rollback; bitwardenSaved = [bool]$sec.bitwardenSaved; updated = (Get-Date -Format 's') }
  $p = Get-FsSecretPath $dir $sec.site; $tmp = $p + '.tmp'
  [IO.File]::WriteAllText($tmp, (Protect-FsText ($keep | ConvertTo-Json -Depth 6 -Compress)))
  Move-Item -LiteralPath $tmp -Destination $p -Force
}
function Save-FsUsual([string]$dir, [string[]]$list) { New-Item -ItemType Directory -Force -Path $dir | Out-Null; [IO.File]::WriteAllText((Join-Path $dir 'wireit-usual.dat'), (Protect-FsText (ConvertTo-Json @($list) -Compress))) }
function New-FsSitePassword([int]$length = 14) {
  # Hikvision: 8-16 characters, 2+ kinds. Dahua: 8-32, no ' " ; : &. Only @ ! * as symbols (safe in a Dahua URL and in XML).
  $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '@!*'); $all = -join $sets
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    for ($t = 0; $t -lt 50; $t++) {
      $c = New-Object System.Collections.Generic.List[char]
      foreach ($s in $sets) { $c.Add($s[(Get-FsRandom $rng $s.Length)]) }
      while ($c.Count -lt $length) { $c.Add($all[(Get-FsRandom $rng $all.Length)]) }
      for ($i = $c.Count - 1; $i -gt 0; $i--) { $j = Get-FsRandom $rng ($i + 1); $x = $c[$i]; $c[$i] = $c[$j]; $c[$j] = $x }
      $pw = -join $c
      if ($pw -notmatch '(?i)admin' -and $pw -notmatch '(.)\1\1' -and '@!*'.IndexOf($pw[0]) -lt 0) { return $pw }
    }
    return $pw
  } finally { $rng.Dispose() }
}
function Get-FsRandom($rng, [int]$n) { $b = New-Object byte[] 4; do { $rng.GetBytes($b); $v = [BitConverter]::ToUInt32($b, 0) } while ($v -ge ([uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$n))); return [int]($v % [uint32]$n) }

# ---------------- Dahua search (read-only, the same packet ConfigTool sends; answers even from the wrong IP scheme) ----------------
function ConvertFrom-FsDhipAnswer([byte[]]$b, [string]$from = '') {
  # 32-byte DHIP header, then JSON {"method":"client.notifyDevInfo","params":{"deviceInfo":{...}}}
  $s = [Text.Encoding]::UTF8.GetString($b); $i = $s.IndexOf('{'); if ($i -lt 0) { return $null }
  try { $j = $s.Substring($i).TrimEnd([char]0, "`n", "`r") | ConvertFrom-Json } catch { return $null }
  $di = $null; if ($j.PSObject.Properties['params'] -and $j.params.PSObject.Properties['deviceInfo']) { $di = $j.params.deviceInfo }; if (-not $di) { return $null }
  $v4 = $di.IPv4Address; $ip = $(if ($v4) { [string]$v4.IPAddress } else { $from })
  if (-not $ip) { return $null }
  $mac = ''; if ($di.PSObject.Properties['MAC']) { $mac = [string]$di.MAC } elseif ($j.PSObject.Properties['mac']) { $mac = [string]$j.mac }
  $type = [string]$di.DeviceType; $kind = $(if ($type -match '(?i)NVR|XVR|DVR|HCVR') { 'nvr' } else { 'camera' })
  $init = $true; if ($di.PSObject.Properties['Init'] -and [string]$di.Init -match '^(0|false|uninit)') { $init = $false }
  return [pscustomobject]@{ brand = 'Dahua'; model = $type; serial = [string]$di.SerialNo; mac = $mac; ip = $ip; firmware = [string]$di.Version; kind = $kind; activated = $init; dhcp = ($v4 -and [string]$v4.DhcpEnable -eq 'True') }
}
function Find-FsDahua([int]$seconds = 4) {
  $out = @{}
  $body = [Text.Encoding]::UTF8.GetBytes('{"method":"DHDiscover.search","params":{"mac":"","uni":1}}' + "`n")
  $hdr = New-Object byte[] 32; [byte[]]$m = 0x20, 0, 0, 0, 0x44, 0x48, 0x49, 0x50; [Array]::Copy($m, $hdr, 8)
  [Array]::Copy([BitConverter]::GetBytes([int]$body.Length), 0, $hdr, 16, 4); [Array]::Copy([BitConverter]::GetBytes([int]$body.Length), 0, $hdr, 24, 4)
  $pkt = New-Object byte[] (32 + $body.Length); [Array]::Copy($hdr, $pkt, 32); [Array]::Copy($body, 0, $pkt, 32, $body.Length)
  $u = $null
  try {
    $u = New-Object Net.Sockets.UdpClient; $u.Client.SetSocketOption('Socket', 'ReuseAddress', $true); $u.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, 37810)))
    try { $u.JoinMulticastGroup([Net.IPAddress]::Parse('239.255.255.251')) } catch {}
    $u.EnableBroadcast = $true; $u.Client.ReceiveTimeout = 500
    foreach ($dst in @('239.255.255.251', '255.255.255.255')) { try { [void]$u.Send($pkt, $pkt.Length, (New-Object Net.IPEndPoint([Net.IPAddress]::Parse($dst), 37810))) } catch {} }
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
      try { $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $b = $u.Receive([ref]$ep); $d = ConvertFrom-FsDhipAnswer $b $ep.Address.ToString(); if ($d -and -not $out.ContainsKey($d.ip)) { $out[$d.ip] = $d } } catch {}
    }
  } catch { Fs-LogLine ('Dahua search could not run: ' + $_.Exception.Message) } finally { if ($u) { $u.Close() } }
  return @($out.Values)
}
