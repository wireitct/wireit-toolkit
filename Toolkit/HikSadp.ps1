<#
 HikSadp.ps1 - WireIt Toolkit 2.1: talking SADP (Hikvision's own "Search Active Devices Protocol", UDP 37020, multicast 239.255.255.250).
 Public sources only for the protocol (MatrixEditor/hiktools, cameronnewman/hikvision-tooling, Hikvision's own SADP guides).
 What it does: find every Hik device on ANY subnet (SADP is layer 2: the PC needs no address on the camera's subnet),
 export a device's password-reset request ("Forgot password > Export file") and import Hikvision's returned unlock file.
 It is the ONLY password path: Hikvision's official reset (the device is asked for its request file; Hikvision answers with an unlock file).
 No password guessing, no default-password tries, no exploits.
 Dot-sourced by HikReset.ps1 and the tests. Test harness: $script:SadpTest = '127.0.0.1:<port>' sends everything to a fake responder.
#>
$script:SadpGroup = '239.255.255.250'
$script:SadpPort = 37020
$script:SadpTest = ''          # TEST ONLY: 'ip:port' of tests\hikreset\fake_sadp.py (unicast on loopback)
$script:SadpLog = $null        # optional scriptblock { param($line) } - never given a password or a key
function Sadp-Log([string]$s) { if ($script:SadpLog) { try { & $script:SadpLog $s } catch {} } }
function Sadp-Esc([string]$s) { return [Security.SecurityElement]::Escape([string]$s) }

# ---------------- probes ----------------
# Types that SADP uses (names from the public tools): inquiry, inquiry_v32, getencryptstring(_v31) = export request,
# exchangecode, resetPassword (+Code +Password) = import, activate, update (= set IP).
function New-SadpProbe([string]$Type, [string]$Mac = '', [hashtable]$Extra = $null) {
  $x = '<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>' + ([guid]::NewGuid().ToString().ToUpper()) + '</Uuid>'
  if ($Mac) { $x += '<MAC>' + (Sadp-Esc $Mac) + '</MAC>' }
  $x += '<Types>' + (Sadp-Esc $Type) + '</Types>'
  if ($Extra) { foreach ($k in $Extra.Keys) { $x += '<' + $k + '>' + (Sadp-Esc ([string]$Extra[$k])) + '</' + $k + '>' } }
  return $x + '</Probe>'
}
function ConvertTo-SadpMac([string]$m) { $h = ($m -replace '[^0-9A-Fa-f]', '').ToUpper(); if ($h.Length -ne 12) { return '' }; return (($h -split '(?<=\G..)(?!$)') -join '-').ToLower() }
function Get-SadpTag([string]$x, [string]$name) { $m = [regex]::Match($x, '<(?:\w+:)?' + $name + '>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value.Trim()) } else { return '' } }
# Hikvision's 9-character short serial (the form field): ...CCRR<9>WCVU for NVRs, last 9 for cameras
function Get-HikShortSerial([string]$sn) { $m = [regex]::Match($sn, '\d{8}[A-Z]{4}([A-Z0-9]{9})(?:[A-Z]{4})?$'); if ($m.Success) { return $m.Groups[1].Value }; if ($sn.Length -ge 9) { return $sn.Substring($sn.Length - 9) }; return $sn }

# ---------------- sockets ----------------
function Get-SadpLocalIps {
  $ips = @()
  try {
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback' -or $ni.NetworkInterfaceType -eq 'Tunnel') { continue }
      foreach ($ua in $ni.GetIPProperties().UnicastAddresses) { if ($ua.Address.AddressFamily -eq 'InterNetwork' -and -not $ua.Address.ToString().StartsWith('169.254.')) { $ips += $ua.Address.ToString() } }
    }
  } catch {}
  return @($ips | Select-Object -Unique)
}
# 2.2.5: on Windows an ICMP "port unreachable" (a probe to an address/port nobody listens on) makes the NEXT receive on that UDP socket fail
# with WSAECONNRESET (10054), and answers that are already waiting are lost with it. SIO_UDP_CONNRESET off = Windows keeps receiving.
function Disable-SadpConnReset($u) {
  if ($env:OS -ne 'Windows_NT') { return }
  try { [void]$u.Client.IOControl(-1744830452, [byte[]]@(0, 0, 0, 0), $null) } catch { Sadp-Log ('SADP: could not switch off UDP connection-reset reports: ' + $_.Exception.Message) }
}
function Open-SadpSockets {
  $socks = @()
  if ($script:SadpTest) {
    $u = New-Object Net.Sockets.UdpClient; $u.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback), 0)); $u.Client.ReceiveTimeout = 300; Disable-SadpConnReset $u
    $ep = $script:SadpTest.Split(':'); $socks += [pscustomobject]@{ udp = $u; local = '127.0.0.1'; dest = (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($ep[0])), ([int]$ep[1])) }
    return $socks
  }
  foreach ($ip in (Get-SadpLocalIps)) {
    try {
      $u = New-Object Net.Sockets.UdpClient
      $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
      try { $u.Client.ReceiveBufferSize = 4194304 } catch {}
      $u.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($ip)), $script:SadpPort))
      Disable-SadpConnReset $u
      try { $u.JoinMulticastGroup([Net.IPAddress]::Parse($script:SadpGroup), [Net.IPAddress]::Parse($ip)) } catch {}
      $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastInterface, ([Net.IPAddress]::Parse($ip)).GetAddressBytes())
      $u.Client.ReceiveTimeout = 300
      $socks += [pscustomobject]@{ udp = $u; local = $ip; dest = (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($script:SadpGroup)), $script:SadpPort) }
    } catch { Sadp-Log ('SADP: could not open UDP ' + $script:SadpPort + ' on ' + $ip + ' (is SADP / HiTools open? close it and run again)') }
  }
  return $socks
}
function Close-SadpSockets($socks) { foreach ($s in @($socks)) { try { $s.udp.Close() } catch {} } }

# sends $probes to every socket at each time in $resendAt (seconds), reads answers for $seconds. Returns [{ from; text }].
# Our own probes come back through multicast loopback: only <ProbeMatch> answers are kept.
function Invoke-SadpExchange([string[]]$Probes, [double]$Seconds = 3.0, [double[]]$ResendAt = @(0, 0.6, 1.8), $Socks = $null, [scriptblock]$Stop = $null) {
  $own = $false; if ($null -eq $Socks) { $Socks = @(Open-SadpSockets); $own = $true }
  $res = New-Object System.Collections.ArrayList
  $t0 = Get-Date; $next = 0
  try {
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
      if ($next -lt $ResendAt.Count -and ((Get-Date) - $t0).TotalSeconds -ge $ResendAt[$next]) {
        foreach ($s in $Socks) { foreach ($p in $Probes) { $b = [Text.Encoding]::UTF8.GetBytes($p); try { [void]$s.udp.Send($b, $b.Length, $s.dest) } catch {} } }
        $next++
      }
      foreach ($s in $Socks) {
        while ($s.udp.Available -gt 0) {
          $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0
          try { $b = $s.udp.Receive([ref]$ep); $t = [Text.Encoding]::UTF8.GetString($b); if ($t -match '<ProbeMatch') { [void]$res.Add([pscustomobject]@{ from = $ep.Address.ToString(); text = $t }) } } catch {}
        }
      }
      if ($Stop -and (& $Stop $res)) { break }
      Start-Sleep -Milliseconds 40
    }
  } finally { if ($own) { Close-SadpSockets $Socks } }
  return ,$res.ToArray()
}

# ---------------- discovery ----------------
function ConvertFrom-SadpAnswer([string]$x) {
  $sn = Get-SadpTag $x 'DeviceSN'; $mac = ConvertTo-SadpMac (Get-SadpTag $x 'MAC')
  if (-not $sn -and -not $mac) { return $null }
  $act = Get-SadpTag $x 'Activated'
  $ra = @(); foreach ($f in 'PasswordResetAbility', 'ResetAbility', 'PasswordResetModeSecond', 'SupportSecurityQuestion', 'SupportMailBox', 'SupportGUID') { $v = Get-SadpTag $x $f; if ($v) { $ra += ($f + '=' + $v) } }
  $desc = Get-SadpTag $x 'DeviceDescription'; $dt = Get-SadpTag $x 'DeviceType'
  return [pscustomobject]@{
    brand = 'Hikvision'; model = $desc; deviceType = $dt; serial = $sn; shortSerial = (Get-HikShortSerial $sn); mac = $mac; ip = (Get-SadpTag $x 'IPv4Address'); mask = (Get-SadpTag $x 'IPv4SubnetMask'); gw = (Get-SadpTag $x 'IPv4Gateway')
    firmware = ((Get-SadpTag $x 'SoftwareVersion') + ' ' + (Get-SadpTag $x 'DSPVersion')).Trim(); activated = ($act -match '^(?i)true|1$'); activatedText = $act
    bootTime = (Get-SadpTag $x 'BootTime'); httpPort = (Get-SadpTag $x 'HttpPort'); cmdPort = (Get-SadpTag $x 'CommandPort'); dhcp = ((Get-SadpTag $x 'DHCP') -match '^(?i)true|1$')
    resetAbility = ($ra -join ' '); encrypt = ((Get-SadpTag $x 'Encrypt') -match '^(?i)true$'); salt = (Get-SadpTag $x 'Salt'); deviceLock = (Get-SadpTag $x 'DeviceLock')
    kind = $(if ([int]('0' + (Get-SadpTag $x 'DigitalChannelNum')) -gt 1 -or [int]('0' + (Get-SadpTag $x 'AnalogChannelNum')) -gt 0 -or $desc -match '^(?i)(i?DS-(7|8|9)\d|ERI-|HWN-|NVR|DVR|XVR|iDS-)') { 'nvr' } else { 'camera' })
  }
}
# every Hikvision device that answers, on any subnet. Returns objects (one per MAC), sorted by IP.
function Find-HikSadp([double]$Seconds = 3.5, $Socks = $null) {
  $pr = @((New-SadpProbe 'inquiry'), (New-SadpProbe 'inquiry_v32'))
  $ans = Invoke-SadpExchange $pr $Seconds @(0, 0.6, 1.8) $Socks
  $byMac = @{}
  foreach ($a in $ans) { $d = ConvertFrom-SadpAnswer $a.text; if ($d) { $k = $(if ($d.mac) { $d.mac } else { $d.serial }); if (-not $byMac.ContainsKey($k) -or (-not $byMac[$k].ip -and $d.ip)) { $byMac[$k] = $d } } }
  $list = @($byMac.Values)
  try { $list = @($list | Sort-Object { try { [version]$_.ip } catch { [version]'0.0.0.0' } }) } catch {}
  return $list
}

# ---------------- export the password-reset request ----------------
# SADP's "Forgot password > Export file" saves ONE line: the device's base64 "safe code" (starts 03 00 00 00 = "AwAAA...") followed directly by the
# device's full serial number. Seen on real files from SADP 3.1.4.4 (3 Hewlett St, Nov 6 2026: 3x ECI-T44F2 + 1x ERI-K108-P8), and the 03000000 flag
# matches the public hiktools "SafeCode" class. So the export = ask the device for its Code, write Code + DeviceSN.
# Which Types name SADP uses for the ask is tried in this order; the first answer with a Code that decodes to the 03000000 flag wins.
$script:SadpExportTypes = @('getcode', 'exchangecode', 'getencryptstring_v31', 'getencryptstring')
$script:SadpExportTags = @('Code', 'EncryptString', 'SecurityCode')
function Test-HikSafeCode([string]$c) { try { $b = [Convert]::FromBase64String($c.Trim()); return ($b.Length -ge 24 -and $b[0] -eq 3 -and $b[1] -eq 0 -and $b[2] -eq 0 -and $b[3] -eq 0) } catch { return $false } }
function Get-SadpRequestString([string]$x) { foreach ($t in $script:SadpExportTags) { $v = Get-SadpTag $x $t; if ($v -and (Test-HikSafeCode $v)) { return [pscustomobject]@{ tag = $t; value = $v } } }; return $null }
function Request-HikResetExport($dev, [double]$Seconds = 4.0) {
  # asks THIS device (by MAC) for its request code. Returns { ok; type; raw; request; error }
  foreach ($ty in $script:SadpExportTypes) {
    $p = New-SadpProbe $ty $dev.mac $(if ($ty -eq 'exchangecode') { @{ Code = '' } } else { $null })
    Sadp-Log ('SADP ' + $ty + ' -> ' + $dev.mac)
    $ans = Invoke-SadpExchange @($p) $Seconds @(0, 1.0, 2.2)
    foreach ($a in $ans) {
      if ((ConvertTo-SadpMac (Get-SadpTag $a.text 'MAC')) -ne $dev.mac) { continue }
      $rq = Get-SadpRequestString $a.text
      if ($rq) { return [pscustomobject]@{ ok = $true; type = $ty; raw = $a.text; request = $rq; bootTime = (Get-SadpTag $a.text 'BootTime'); error = '' } }
    }
  }
  return [pscustomobject]@{ ok = $false; type = ''; raw = ''; request = $null; bootTime = ''; error = 'the device did not give its request code (an old firmware without the file reset, or the PC blocks UDP 37020)' }
}
# Writes the request file exactly like SADP does: <Code><DeviceSN> in one line, no newline. Name: <model>-<serial>.xml (SADP: "ECI-T44F2-<serial>.xml").
function Save-HikResetFile($dev, $exp, [string]$OutDir) {
  # 2.2.5: null guard - no request code (export failed / no answer) = no file and no crash (2.2.4: "You cannot call a method on a null-valued expression")
  if ($null -eq $exp -or -not $exp.ok -or $null -eq $exp.request -or -not ([string]$exp.request.value).Trim() -or $null -eq $dev -or -not [string]$dev.serial) {
    Sadp-Log ('SADP: no request code to save for ' + $(if ($dev) { [string]$dev.mac } else { 'an unknown device' }) + ' - no file written'); return $null
  }
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $path = Get-HikResetFilePath $dev $OutDir
  $text = (([string]$exp.request.value).Trim() + [string]$dev.serial)
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
  # 2.2.20 (class A): the file counts as saved only when it reads back exactly as written
  if ([IO.File]::ReadAllText($path) -ne $text) { Sadp-Log ('SADP: the request file ' + $path + ' did not read back as written'); return $null }
  return $path
}
# 2.2.20 (Codex 2.2.19 R14): where Save-HikResetFile puts a device's request file. The reset record names it BEFORE the device is asked,
# so a run that stops after the export (or cannot save its result) finds that exact file next time instead of exporting again.
function Get-HikResetFilePath($dev, [string]$OutDir) {
  $name = (([string]$dev.model) -replace '[^A-Za-z0-9\-]+', '_') + '-' + (([string]$dev.serial) -replace '[^A-Za-z0-9\-]+', '_') + '.xml'
  return (Join-Path $OutDir $name)
}

# ---------------- import the unlock file / key ----------------
# What Hikvision returns: an "encrypted file" (one line, like the request) or a short key. SADP's "Import file" sends it to the device.
# The exact SADP import message is not in any public source: the Toolkit tries the public command forms below, at most $script:SadpImportMax
# tries per device (so a wrong form can never run a device into a lock), and tells you plainly when none worked ("finish in SADP").
# Success is never taken from the answer alone: the caller checks that the new password really logs in.
$script:SadpImportMax = 3
function Read-HikUnlock([string]$Path = '', [string]$Key = '') {
  if ($Key) { return [pscustomobject]@{ kind = 'key'; code = $Key.Trim(); file = '' } }
  $raw = [IO.File]::ReadAllText($Path).Trim()
  $c = ''
  foreach ($t in @('Code', 'SecurityCode', 'EncryptString', 'ResetCode', 'Key', 'UnlockCode')) { $v = Get-SadpTag $raw $t; if ($v) { $c = $v; break } }
  if (-not $c) { $one = ($raw -replace '<[^>]+>', ' ').Trim(); if ($one -and $one.Length -le 4000 -and $one -notmatch '\s') { $c = $one } }
  if (-not $c) { $c = $raw }
  return [pscustomobject]@{ kind = 'file'; code = $c; file = $Path }
}
$script:SadpAllowPlainPassword = $false   # 2.2.3 (Codex #6): see Import-HikUnlock
$script:SadpImportForms = @(
  @{ name = 'resetPassword'; type = 'resetPassword'; codeTag = 'Code' },
  @{ name = 'securityCode'; type = 'securityCode'; codeTag = 'SecurityCode' },
  @{ name = 'resetPassword+serial'; type = 'resetPassword'; codeTag = 'Code'; withSerial = $true }
)

# ---------------- SADP's own reset (what SADP 3.1.4.4 does on "Forgot password > Import file", read from its traffic on Nov 6 2026) ----------------
# 1) "exchangecode": we send a fresh RSA-1024 public key (PKCS#1 DER, base64). The device answers a session key encrypted with it.
# 2) "reset": <Password> = the new password encrypted (AES, 32 bytes = two 16-byte blocks, base64) with that session key, <Code> = the 8-character key from Hikvision's email.
# The AES layout is the one Hikvision documents for its ISAPI activation (first block proves the session key, second block is the password, zero padded);
# it is tried in at most 2 layouts. UNVERIFIED against a real device until the first success; success is only believed after a login check.
function ConvertTo-DerLength([int]$n) { if ($n -lt 128) { return ,[byte]$n }; if ($n -lt 256) { return [byte[]]@(0x81, $n) }; return [byte[]]@(0x82, [byte]($n -shr 8), [byte]($n -band 255)) }
function ConvertTo-DerInt([byte[]]$b) {
  $i = 0; while ($i -lt $b.Length - 1 -and $b[$i] -eq 0) { $i++ }; $v = New-Object byte[] ($b.Length - $i); [Array]::Copy($b, $i, $v, 0, $v.Length)
  if ($v[0] -band 0x80) { $v = [byte[]](@(0) + $v) }
  return [byte[]](@(0x02) + (ConvertTo-DerLength $v.Length) + $v)
}
function New-SadpKeyPair {
  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 1024
  $p = $rsa.ExportParameters($false)
  $seq = [byte[]]((ConvertTo-DerInt $p.Modulus) + (ConvertTo-DerInt $p.Exponent))
  $der = [byte[]](@(0x30) + (ConvertTo-DerLength $seq.Length) + $seq)
  return [pscustomobject]@{ rsa = $rsa; der = $der; b64 = [Convert]::ToBase64String($der) }
}
function Protect-SadpPassword([string]$Password, [string]$SessionKeyText, [int]$Layout = 1) {
  # $SessionKeyText = the last 32 characters the device sent back (hex text). AES-128-ECB, key = those 32 hex chars as 16 bytes.
  $hex = $SessionKeyText.Substring($SessionKeyText.Length - 32)
  $key = New-Object byte[] 16; for ($i = 0; $i -lt 16; $i++) { $key[$i] = [Convert]::ToByte($hex.Substring(2 * $i, 2), 16) }
  $aes = [Security.Cryptography.Aes]::Create(); $aes.Mode = 'ECB'; $aes.Padding = 'None'; $aes.Key = $key
  $enc = $aes.CreateEncryptor()
  $first = $(if ($Layout -eq 2) { $key } else { [Text.Encoding]::ASCII.GetBytes($hex.Substring(0, 16)) })
  $pw = [Text.Encoding]::UTF8.GetBytes($Password); $len = [int]([math]::Ceiling($pw.Length / 16.0) * 16); if ($len -lt 16) { $len = 16 }
  $pad = New-Object byte[] $len; [Array]::Copy($pw, $pad, $pw.Length)
  $c1 = $enc.TransformFinalBlock($first, 0, 16); $c2 = $enc.TransformFinalBlock($pad, 0, $len)
  $aes.Dispose()
  return [Convert]::ToBase64String([byte[]]($c1 + $c2))
}
function Invoke-SadpKeyExchange($dev, [double]$Seconds = 4.0) {
  $kp = New-SadpKeyPair
  $p = New-SadpProbe 'exchangecode' $dev.mac ([ordered]@{ Code = $kp.b64 })
  $uuid = Get-SadpTag $p 'Uuid'
  $ans = Invoke-SadpExchange @($p) $Seconds @(0, 1.2) $null ({ param($r) @($r | Where-Object { $_.text -match $uuid -and $_.text -match '<Code>' }).Count -gt 0 }.GetNewClosure())
  foreach ($a in $ans) {
    if ($a.text -notmatch $uuid) { continue }
    $c = Get-SadpTag $a.text 'Code'; if (-not $c) { continue }
    try { $ct = [Convert]::FromBase64String($c); $pt = $kp.rsa.Decrypt($ct, $false); $txt = [Text.Encoding]::ASCII.GetString($pt) } catch { Sadp-Log '  key exchange: could not decrypt the device answer'; continue }
    if ($txt.Length -lt 32 -or $txt.Substring($txt.Length - 32) -notmatch '^[0-9a-fA-F]{32}$') { Sadp-Log '  key exchange: session key not in the expected shape'; continue }
    return [pscustomobject]@{ ok = $true; key = $txt }
  }
  return [pscustomobject]@{ ok = $false; key = '' }
}
function Import-HikUnlockReset($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) {
  # SADP's real way. At most 2 layouts; a "failed" answer does not use up Hikvision's key (seen on the wire: failed, then success with the same key).
  # 2.2.20 (Codex 2.2.19 R13 twin, class F): $sent says whether a reset was sent to the device. A reset with NO answer is NOT CONFIRMED (it
  # may have worked): the second layout is NOT sent after it (2.2.19 sent it, and its "failed" - the key already used - was then recorded
  # as "the device refused the file"). Only an answer that says no lets the second layout go.
  $last = ''; $tries = 0; $sent = $false; $kxNo = $false
  foreach ($layout in 1, 2) {
    $tries++
    $kx = Invoke-SadpKeyExchange $dev; if (-not $kx.ok) { $kxNo = $true; break }
    $enc = Protect-SadpPassword $NewPassword $kx.key $layout
    $p = New-SadpProbe 'reset' $dev.mac ([ordered]@{ Password = $enc; Code = $unlock.code })
    Sadp-Log ('SADP reset (layout ' + $layout + ') -> ' + $dev.mac + ' (code and password hidden)')
    $sent = $true
    $ans = Invoke-SadpExchange @($p) $Seconds @(0, 1.5) $null ({ param($r) @($r | Where-Object { $_.text -match '<Types>reset</Types>' }).Count -gt 0 })
    $thisR = ''
    foreach ($a in $ans) {
      if ((ConvertTo-SadpMac (Get-SadpTag $a.text 'MAC')) -ne $dev.mac) { continue }
      $r = Get-SadpTag $a.text 'Result'; Sadp-Log ('  answer: ' + $r)
      if ($r -match '^(?i)success') { return [pscustomobject]@{ ok = $true; result = $r; form = ('reset/layout' + $layout); tries = $tries; error = ''; sent = $true } }
      if ($r) { $last = $r; $thisR = $r }
    }
    if (-not $thisR) { $last = ''; break }   # no answer to THIS reset: stop, NOT CONFIRMED
  }
  $why = $(if ($kxNo -and -not $sent) { 'no key exchange answer (nothing was sent)' } elseif ($last) { 'the device answered "' + $last + '"' } else { 'the device did not answer the reset - NOT CONFIRMED (it may have worked)' })
  return [pscustomobject]@{ ok = $false; result = $last; form = ''; tries = $tries; error = $why; sent = $sent }
}

function Import-HikUnlock($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) {
  # Returns { ok; result; form; tries; error }. Code and password are never logged.
  # SADP's own way first: the key Hikvision mailed (8 characters, also what the mailed file holds), after a key exchange
  if ($unlock.code -match '^[0-9A-Za-z]{8}$' -and -not $script:SadpOldForms) { $rr = Import-HikUnlockReset $dev $unlock $NewPassword $Seconds; if ($rr.ok -or $rr.result -or $rr.sent -or $script:SadpNoLegacy -or -not $script:SadpAllowPlainPassword) { return $rr } }
  # 2.2.3 (Codex #6): the old import forms put the NEW password in the multicast packet in plain text (anyone on the network, or on
  # another connected interface, can read it). They are off unless config fixSite.sadpLegacyPlainPassword = true (Admin's choice).
  if (-not $script:SadpAllowPlainPassword) { return [pscustomobject]@{ ok = $false; result = ''; form = ''; tries = 0; error = 'this unlock file needs the old SADP form, which would send the new password unencrypted over the network: not used. Import it in Hikvision SADP by hand.'; sent = $false } }
  $tries = 0; $last = ''; $sent = $false; $thisR = ''
  foreach ($f in $script:SadpImportForms) {
    if ($tries -ge $script:SadpImportMax) { break }
    # 2.2.20: the old forms are each one firmware generation's import type; a device silently ignores a type it does not know (seen on
    # the wire and in the test device), so silence to one form is "not this form" and the next is tried. If NO form got any answer the
    # result is NOT CONFIRMED (sent, no result), never a refusal, and the caller does not import again on its own (class F).
    $tries++; $sent = $true; $thisR = ''
    $code = $unlock.code; if ($f.withSerial -and $code -notlike ('*' + $dev.serial)) { $code = $code + [string]$dev.serial }
    $p = New-SadpProbe $f.type $dev.mac ([ordered]@{ ($f.codeTag) = $code; Password = $NewPassword })
    Sadp-Log ('SADP ' + $f.name + ' -> ' + $dev.mac + ' (code and password hidden)')
    $ans = Invoke-SadpExchange @($p) $Seconds @(0, 1.5)
    foreach ($a in $ans) {
      if ((ConvertTo-SadpMac (Get-SadpTag $a.text 'MAC')) -ne $dev.mac) { continue }
      $r = Get-SadpTag $a.text 'Result'; if (-not $r) { $r = Get-SadpTag $a.text 'Status' }
      Sadp-Log ('  answer: ' + (($a.text -replace '<(Salt|Code|Password|SecurityCode)>[^<]*', '<$1>(hidden)') -replace '\s+', ' ').Substring(0, [Math]::Min(300, ($a.text -replace '\s+', ' ').Length)))
      if ($r -match '^(?i)\s*(success|ok|true)\s*$') { return [pscustomobject]@{ ok = $true; result = $r; form = $f.name; tries = $tries; error = ''; sent = $true } }   # 2.2.19 (class C): the whole answer, not a word inside it
      if ($r) { $last = $r; $thisR = $r }
    }
  }
  $why = $(if ($last) { 'the device answered "' + $last + '"' + $(if ($last -match 'denied|fail') { ' (the file is only good for this exact request, for 48 hours, and only if the device has not restarted since)' } else { '' }) } else { 'the device did not answer the import - NOT CONFIRMED (it may have worked)' })
  return [pscustomobject]@{ ok = $false; result = $last; form = ''; tries = $tries; error = $why; sent = $sent }
}
# SADP "update": set the address (needs the device password). Used only after the reset, to move a device before it has a reachable address.
function Set-HikSadpNet($dev, [string]$Password, [string]$Ip, [string]$Mask, [string]$Gw, [double]$Seconds = 5.0) {
  $p = New-SadpProbe 'update' $dev.mac ([ordered]@{ PWErrorParse = 'true'; Password = $Password; IPv4Address = $Ip; CommandPort = $(if ($dev.cmdPort) { $dev.cmdPort } else { '8000' }); IPv4SubnetMask = $Mask; IPv4Gateway = $Gw; DHCP = 'false' })
  Sadp-Log ('SADP update ' + $dev.mac + ' -> ' + $Ip + ' (password hidden)')
  $ans = Invoke-SadpExchange @($p) $Seconds @(0, 1.5) $null
  foreach ($a in $ans) { if ((ConvertTo-SadpMac (Get-SadpTag $a.text 'MAC')) -eq $dev.mac) { $r = Get-SadpTag $a.text 'Result'; return ($r -match '^(?i)\s*(success|ok|true)\s*$') } }
  return $false
}
function Set-HikSadpActivate($dev, [string]$Password, [double]$Seconds = 5.0) {
  $p = New-SadpProbe 'activate' $dev.mac ([ordered]@{ Password = $Password })
  Sadp-Log ('SADP activate ' + $dev.mac + ' (password hidden)')
  $ans = Invoke-SadpExchange @($p) $Seconds @(0, 1.5) $null
  foreach ($a in $ans) { if ((ConvertTo-SadpMac (Get-SadpTag $a.text 'MAC')) -eq $dev.mac) { $r = Get-SadpTag $a.text 'Result'; return ($r -match '^(?i)\s*(success|ok|true)\s*$') } }
  return $false
}
