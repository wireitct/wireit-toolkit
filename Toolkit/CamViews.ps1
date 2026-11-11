# CamViews.ps1 - WireIt Toolkit: "Save camera pictures" (Nov 2 2026, Moshe: "a picture of the camera before it went down")
# Takes one picture of every camera on an NVR (or one lone camera), READ-ONLY, and sends it to the WireIt service log
# (the site's Drive folder "Camera views": current + previous picture per camera, with the date). Techs see them on the
# site page (QR + PIN, that site only) and a camera that goes down shows its last picture there.
#   Hikvision: ISAPI /ISAPI/Streaming/channels/<ch>02/picture (sub stream, small), else <ch>01.
#   Uniview:   LAPI /LAPI/V1.0/Channels/<id>/Media/Video/Streams/<1|0>/Snapshot (from Uniview's LiteAPI docs; NOT yet tried on a real unit).
# A camera that does not answer is NOT re-pictured, so its last good picture stays.
# Also sends a tiny signature of each view (64x36 gray + sharpness) so the service log can flag "View changed?"
# (turned / covered / blurry) and "Missing" cameras. Nothing on the NVR or cameras is changed. No password is stored or logged.
# Upload key: secrets\upload-key.bin (this PC only, Windows DPAPI) - make it with "Set upload key.cmd"; or the Vendor Monitor's
# key on the same PC. No key / no internet: pictures wait in outbox\ and go next time (and stay in pictures\ on this PC).
# Usage:  CamViews.ps1 -Nvr 192.168.1.20 -Site "WI-061"        (asks for the NVR password, hidden)
#         CamViews.ps1 -SendOutbox                              (send what is waiting)
#         . .\CamViews.ps1 -Lib ; Save-CameraViews ...          (used by Fix NVR at the end of Snapshot / Fix)
#         CamViews.ps1 -Nvr 192.168.1.20 -Site WI-061 -Remember   (a PC that stays on the site's network: keep this NVR + its login,
#                                                                encrypted for this PC only) then  CamViews.ps1 -InstallTask
#                                                                = a daily 12:30 refresh, hidden, only cameras that answer
#         CamViews.ps1 -PrepDir <folder>                         (Vendor Monitor's DW pictures: shrink + signature, one JSON line per .jpg)
param(
  [string]$Nvr = '', [string]$Site = '', [string]$User = 'admin', [string]$CredFile = '', [ValidateSet('auto','hik','uniview')][string]$Vendor = 'auto',
  [int]$RecorderNo = 1, [string]$ApiUrl = '', [switch]$NoUpload, [switch]$SendOutbox, [switch]$SetKey, [string]$PrepDir = '', [switch]$Remember, [switch]$Auto, [switch]$InstallTask, [switch]$RemoveTask, [string]$Mock = '', [switch]$Lib
)
$ErrorActionPreference = 'Stop'
$script:CvHere = $PSScriptRoot
if (-not $script:CvHere) { $script:CvHere = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:CvMock = $Mock
$script:CvIsPs5 = $PSVersionTable.PSVersion.Major -le 5
$script:CvApi = 'https://wireit-api.wireitct.workers.dev/'
try { $c = Get-Content (Join-Path $script:CvHere 'config.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ($c.camviews -and $c.camviews.api_url) { $script:CvApi = [string]$c.camviews.api_url } } catch {}
if ($ApiUrl) { $script:CvApi = $ApiUrl }
$script:CvLogDir = Join-Path $script:CvHere 'logs'
$script:CvOutbox = Join-Path $script:CvHere 'outbox'
$script:CvPics = Join-Path $script:CvHere 'pictures'
$script:CvMaxW = 640; $script:CvQuality = 70; $script:CvBatch = 8
function CvLog([string]$s) { try { New-Item -ItemType Directory -Force -Path $script:CvLogDir | Out-Null; Add-Content -Path (Join-Path $script:CvLogDir ('camviews-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')) -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $s) } catch {} }
function CvSay([string]$s, [string]$color = '') { if (Get-Command -Name 'Say' -CommandType Function -ErrorAction SilentlyContinue) { Say $s $color; return }; if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }; CvLog ('SAY ' + $s) }
function CvXVal([string]$xml, [string]$name) { $m = [regex]::Match($xml, '<(?:\w+:)?' + $name + '(?:\s[^>]*)?>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '' } }
function CvBase([string]$ip) { if ($script:CvMock) { return ($script:CvMock + '/dev/' + $ip) }; return ('http://' + $ip) }

# 2.2.2 (Codex H2): the same private-IPv4 test in plain PowerShell, for PowerShell 7's per-call certificate skip and curl's -k
function Test-WireItLanHost([string]$h) {
  if (-not $h) { return $false }; $a = $null; if (-not [Net.IPAddress]::TryParse($h.Trim('[', ']'), [ref]$a)) { return $false }
  if ($a.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
  $b = $a.GetAddressBytes()
  return ($b[0] -eq 10 -or $b[0] -eq 127 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254))
}
# 2.2.7 (Codex file-by-file F06): over plain HTTP a password is only answered to a Digest challenge (the password itself never
# crosses the wire). A device - or a box pretending to be one - that asks only for Basic gets NO password over plain HTTP.
# Same check in FixNVR.ps1, CamViews.ps1, NetCheck.ps1 and SiteCheck.ps1 (FixSite and NvrHealth have had it since 2.2.3).
$script:WiAuthSeen = @{}
function Test-WireItPlainBasicOnly([string]$uri) {
  $u = $null; try { $u = [uri]$uri } catch { return $false }
  if (-not $u -or $u.Scheme -ne 'http') { return $false }
  if ($null -eq $script:WiAuthSeen) { $script:WiAuthSeen = @{} }
  $k = $u.Authority; if ($script:WiAuthSeen.ContainsKey($k)) { return [bool]$script:WiAuthSeen[$k] }
  $basicOnly = $false
  try { $rq = [Net.HttpWebRequest]::Create($u); $rq.Method = 'GET'; $rq.Timeout = 6000; $rq.AllowAutoRedirect = $false; $rs = $rq.GetResponse(); $rs.Close() }
  catch { $ex = $_.Exception; while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
    if ($ex -and $ex.Response) { $h = [string]$ex.Response.Headers['WWW-Authenticate']; if ($h -match '(?i)\bbasic\b' -and $h -notmatch '(?i)\bdigest\b') { $basicOnly = $true }; try { $ex.Response.Close() } catch {} } }
  $script:WiAuthSeen[$k] = $basicOnly; return $basicOnly
}
# ---- HTTP (digest through -Credential; never Basic over plain HTTP; bytes kept as bytes) ----
function CvGet([string]$url, $cred, [int]$timeout = 12) {
  if ($cred -and -not $script:CvMock -and (Test-WireItPlainBasicOnly $url)) { CvLog ('GET ' + ($url -replace '//[^/@]*@', '//') + ' refused: plain HTTP with Basic login only (the password is not sent)'); return @{ code = 0; bytes = $null; text = ''; err = 'plain HTTP with Basic login only - the password was not sent' } }   # 2.2.7 (F06)
  $tmp = [IO.Path]::GetTempFileName()
  try {
    $a = @{ Uri = $url; Method = 'GET'; UseBasicParsing = $true; TimeoutSec = $timeout; OutFile = $tmp; PassThru = $true }
    if ($cred) { $a.Credential = $cred }
    if (-not $script:CvIsPs5) { if (Test-WireItLanHost ([string]([uri]$url).Host)) { $a.SkipCertificateCheck = $true }; if ($cred) { $a.AllowUnencryptedAuthentication = $true } }   # 2.2.2 (Codex H2): the skip only for a device on the LAN
    $r = Invoke-WebRequest @a
    $b = [IO.File]::ReadAllBytes($tmp)
    return @{ code = [int]$r.StatusCode; bytes = $b; text = [Text.Encoding]::UTF8.GetString($b) }
  } catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    CvLog ('GET ' + ($url -replace '//[^/@]*@', '//') + ' -> ' + $code + ' ' + $_.Exception.Message)
    return @{ code = $code; bytes = $null; text = ''; err = $_.Exception.Message }
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function CvIsJpeg($b) { return ($b -and $b.Length -gt 200 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8) }

# ---- what is on the recorder ----
function Get-CvChannels([string]$ip, $cred, [string]$vendor) {
  $out = New-Object System.Collections.Generic.List[object]
  if ($vendor -ne 'uniview') {
    $d = CvGet ((CvBase $ip) + '/ISAPI/System/deviceInfo') $cred
    if ($d.code -eq 200) {
      $script:CvVendor = 'hik'
      $dt = CvXVal $d.text 'deviceType'
      if ($dt -and $dt -notmatch '(?i)NVR|DVR|HVR|recorder') { $out.Add([pscustomobject]@{ id = '1'; ip = $ip; online = $true; lone = $true }); return ,$out }
      $chs = CvGet ((CvBase $ip) + '/ISAPI/ContentMgmt/InputProxy/channels') $cred
      $st = CvGet ((CvBase $ip) + '/ISAPI/ContentMgmt/InputProxy/channels/status') $cred
      $on = @{}; foreach ($mm in [regex]::Matches($st.text, '(?s)<InputProxyChannelStatus[ >].*?</InputProxyChannelStatus>')) { $on[(CvXVal $mm.Value 'id')] = ((CvXVal $mm.Value 'online') -eq 'true') }
      foreach ($mm in [regex]::Matches($chs.text, '(?s)<InputProxyChannel[ >].*?</InputProxyChannel>')) {
        $id = CvXVal $mm.Value 'id'; if (-not $id) { continue }
        $out.Add([pscustomobject]@{ id = $id; ip = (CvXVal $mm.Value 'ipAddress'); online = $(if ($on.ContainsKey($id)) { $on[$id] } else { $true }); lone = $false })
      }
      return ,$out
    }
    if ($d.code -eq 401) { $script:CvLoginRefused = $true; return ,$out }
  }
  if ($vendor -ne 'hik') {
    $u = CvGet ((CvBase $ip) + '/LAPI/V1.0/Channels/System/ChannelDetailInfos') $cred
    if ($u.code -eq 200) {
      $script:CvVendor = 'uniview'
      try { $j = $u.text | ConvertFrom-Json; $data = $j.Response.Data; if (-not $data) { $data = $j } } catch { $data = $null }
      $arr = @(); if ($data) { foreach ($p in $data.PSObject.Properties) { if ($p.Value -is [array]) { $arr = $p.Value } } }
      foreach ($ch in $arr) {
        $cip = ''; foreach ($n in 'IPAddress', 'Address', 'IP') { if ($ch.$n) { $cip = [string]$ch.$n; break } }
        $st = $null; foreach ($n in 'Status', 'Online', 'OnlineStatus') { if ($null -ne $ch.$n) { $st = ([string]$ch.$n -match '^(1|true|online)$'); break } }
        $out.Add([pscustomobject]@{ id = [string]$ch.ID; ip = $cip; online = $(if ($null -eq $st) { $true } else { $st }); lone = $false })
      }
    } elseif ($u.code -eq 401) { $script:CvLoginRefused = $true }
  }
  return ,$out
}
function Get-CvPicture([string]$ip, $cred, $ch) {
  if ($script:CvVendor -eq 'uniview') { $paths = @(('/LAPI/V1.0/Channels/' + $ch.id + '/Media/Video/Streams/1/Snapshot'), ('/LAPI/V1.0/Channels/' + $ch.id + '/Media/Video/Streams/0/Snapshot')) }
  elseif ($ch.lone) { $paths = @('/ISAPI/Streaming/channels/102/picture', '/ISAPI/Streaming/channels/101/picture') }
  else { $paths = @(('/ISAPI/Streaming/channels/' + $ch.id + '02/picture'), ('/ISAPI/Streaming/channels/' + $ch.id + '01/picture')) }
  foreach ($pp in $paths) { $r = CvGet ((CvBase $ip) + $pp) $cred 20; if ($r.code -eq 200 -and (CvIsJpeg $r.bytes)) { return $r.bytes } }
  return $null
}

# ---- picture: shrink to 640 px + view signature (Windows System.Drawing; on other systems the picture goes as is, no signature) ----
function CvDrawingOk { if ($null -ne $script:CvDraw) { return $script:CvDraw }; try { Add-Type -AssemblyName System.Drawing; $b = New-Object System.Drawing.Bitmap 2, 2; $b.Dispose(); $script:CvDraw = $true } catch { $script:CvDraw = $false }; return $script:CvDraw }
function CvGrayBytes($img, [int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half; $g.DrawImage($img, 0, 0, $w, $h); $g.Dispose()
  $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
  $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $raw = New-Object byte[] ($bd.Stride * $h); [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length); $st = $bd.Stride
  $bmp.UnlockBits($bd); $bmp.Dispose()
  $out = New-Object double[] ($w * $h)
  for ($y = 0; $y -lt $h; $y++) { $o = $y * $st; for ($x = 0; $x -lt $w; $x++) { $i = $o + $x * 3; $out[$y * $w + $x] = 0.114 * $raw[$i] + 0.587 * $raw[$i + 1] + 0.299 * $raw[$i + 2] } }
  return ,$out
}
function Get-CvPrepared($bytes) {
  # -> @{ jpg = bytes (<= 640 px wide); sig = base64 64x36 gray; sh = sharpness }
  $res = @{ jpg = $bytes; sig = ''; sh = $null }
  if (-not (CvDrawingOk)) { return $res }
  $ms = New-Object IO.MemoryStream (, $bytes); $img = $null
  try {
    $img = [System.Drawing.Image]::FromStream($ms)
    if ($img.Width -gt $script:CvMaxW -or $bytes.Length -gt 250000) {
      $w = [Math]::Min($script:CvMaxW, $img.Width); $h = [int][Math]::Round($img.Height * $w / $img.Width)
      $bmp = New-Object System.Drawing.Bitmap $w, $h
      $g = [System.Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; $g.DrawImage($img, 0, 0, $w, $h); $g.Dispose()
      $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
      $ep = New-Object System.Drawing.Imaging.EncoderParameters 1; $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$script:CvQuality)
      $o = New-Object IO.MemoryStream; $bmp.Save($o, $enc, $ep); $bmp.Dispose(); $res.jpg = $o.ToArray()
    }
    $g64 = CvGrayBytes $img 64 36
    $sb = New-Object byte[] 2304; for ($i = 0; $i -lt 2304; $i++) { $sb[$i] = [byte][Math]::Max(0, [Math]::Min(255, [Math]::Round($g64[$i]))) }
    $res.sig = [Convert]::ToBase64String($sb)
    $s = CvGrayBytes $img 320 180
    $sum = 0.0; $sq = 0.0; foreach ($v in $s) { $sum += $v; $sq += $v * $v }; $n = $s.Length; $mean = $sum / $n; $std = [Math]::Sqrt([Math]::Max(0, $sq / $n - $mean * $mean))
    $lap = 0.0; $cnt = 0
    for ($y = 1; $y -lt 179; $y++) { for ($x = 1; $x -lt 319; $x++) { $i = $y * 320 + $x; $lap += [Math]::Abs(4 * $s[$i] - $s[$i - 320] - $s[$i + 320] - $s[$i - 1] - $s[$i + 1]); $cnt++ } }
    $res.sh = [Math]::Round(($lap / $cnt) / ($std + 1), 4)
  } catch { CvLog ('picture prep: ' + $_.Exception.Message) }
  finally { if ($img) { $img.Dispose() }; $ms.Dispose() }
  return $res
}

# ---- upload key (DPAPI, this PC only) ----
function CvUnprotect([string]$path, [string]$entropy) {
  Add-Type -AssemblyName System.Security
  $raw = [IO.File]::ReadAllBytes($path)
  $b = [Security.Cryptography.ProtectedData]::Unprotect($raw, [Text.Encoding]::ASCII.GetBytes($entropy), [Security.Cryptography.DataProtectionScope]::LocalMachine)
  return ([Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json).key
}
function Get-CvKey {
  if ($env:WIREIT_UPLOAD_KEY) { return $env:WIREIT_UPLOAD_KEY }   # tests
  $own = Join-Path $script:CvHere 'secrets\upload-key.bin'
  try { if (Test-Path $own) { return (CvUnprotect $own 'WireIt-Toolkit-v1') } } catch {
    CvLog ('own key: ' + $_.Exception.Message)
    # 2.2.4 (#26): a Toolkit started without "Run as administrator" (UAC) may not be allowed to read the key: say so in plain words
    $ex = $_.Exception; $denied = $false; while ($ex) { if ($ex -is [UnauthorizedAccessException]) { $denied = $true }; $ex = $ex.InnerException }
    if ($denied) { $script:CvKeyDenied = $true; CvSay ('This Windows account may not read the upload key (secrets\upload-key.bin) without admin rights. Right-click the Toolkit > "Run as administrator", or run Install-Toolkit.ps1 as administrator once so your account can read it.') 'Yellow' }
  }
  foreach ($vm in @((Join-Path (Split-Path -Parent $script:CvHere) 'VendorMonitor\secrets\ingest.bin'))) {
    try { if (Test-Path $vm) { return (CvUnprotect $vm 'WireIt-VendorMonitor-v1') } } catch { CvLog ('vendor monitor key: ' + $_.Exception.Message) }
  }
  return ''
}
function Set-CvKey {
  $sec = Read-Host 'Paste the upload key (the service log "push key"; hidden)' -AsSecureString
  $k = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  if ($k -notmatch '^[A-Za-z0-9_-]{24,}$') { CvSay 'That does not look like the key (24+ letters/digits). Nothing saved.' 'Red'; return }
  [void](Save-CvKey $k); $k = $null
}
# 2.2.7 (Codex file-by-file F08): the secrets folder is locked (Administrators + SYSTEM + this login, nothing inherited) BEFORE the key
# goes in, and the lock's own answer is checked: a folder that could not be locked gets no key, and the tech is not told it was saved.
# 2.2.6 wrote the key first, locked the folder afterwards, ignored icacls' exit code and always said "Upload key saved".
function Save-CvKey([string]$k) {
  $dir = Join-Path $script:CvHere 'secrets'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $me = Get-CvSaverSid; $a = @($dir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F'); if ($me) { $a += ('*' + $me + ':(OI)(CI)F') } elseif ($env:USERNAME) { $a += ($env:USERNAME + ':(OI)(CI)F') }
  $locked = $false
  if ($script:CvAclRun) { $locked = ([int](& $script:CvAclRun $a) -eq 0) } else { try { $null = & icacls.exe @a 2>&1; $locked = ($LASTEXITCODE -eq 0) } catch { $locked = $false } }
  if (-not $locked) { CvSay 'The upload key was NOT saved: its folder could not be locked to Administrators (run the Toolkit as an admin and try again).' 'Red'; return $false }
  $data = [Text.Encoding]::UTF8.GetBytes((@{ key = $k } | ConvertTo-Json -Compress))
  if ($script:CvDpapi) { $b = [byte[]](& $script:CvDpapi 'protect' $data) }
  else { Add-Type -AssemblyName System.Security; $b = [Security.Cryptography.ProtectedData]::Protect($data, [Text.Encoding]::ASCII.GetBytes('WireIt-Toolkit-v1'), [Security.Cryptography.DataProtectionScope]::LocalMachine) }
  $kf = Join-Path $dir 'upload-key.bin'
  try { [IO.File]::WriteAllBytes($kf, $b) } catch { CvSay ('The upload key was NOT saved: ' + $_.Exception.Message) 'Red'; return $false }
  # 2.2.20 (Codex 2.2.19 class A sweep): "saved" only when the file reads back exactly as written
  $kb = $null; try { $kb = [IO.File]::ReadAllBytes($kf) } catch { $kb = $null }
  if (-not $kb -or $kb.Length -ne $b.Length -or [Convert]::ToBase64String($kb) -ne [Convert]::ToBase64String($b)) { CvSay 'The upload key was NOT saved: the file does not read back as written.' 'Red'; return $false }
  # 2.2.4 (#26): every local admin USER may read this one file without elevation (UAC); the folder stays admins + SYSTEM + you
  try { $mg = Join-Path $script:CvHere 'ToolkitMigrate.ps1'; if (Test-Path -LiteralPath $mg) { . $mg; $ops = Get-TkRealOps; foreach ($u in @(& $ops.adminUsers)) { [void](& $ops.icacls (Get-TkKeyReadArgs $kf $u)) } } } catch {}
  CvSay 'Upload key saved on this PC (encrypted, this PC only).' 'Green'
  return $true
}

# ---- send (outbox when it can't) ----
function Send-CvBody($body) {
  $json = $body | ConvertTo-Json -Depth 6 -Compress
  try {
    $a = @{ Uri = $script:CvApi; Method = 'POST'; Body = [Text.Encoding]::UTF8.GetBytes($json); ContentType = 'text/plain;charset=utf-8'; UseBasicParsing = $true; TimeoutSec = 90 }
    $r = Invoke-WebRequest @a
    return ($r.Content | ConvertFrom-Json)
  } catch { CvLog ('send: ' + $_.Exception.Message); return $null }
}
# 2.2.19 (Codex 2.2.18 F20, class F): "kept in the outbox" only when the file is written AND reads back the same. Returns $true / $false.
function Save-CvOutbox($body) {
  try {
    New-Item -ItemType Directory -Force -Path $script:CvOutbox -ErrorAction Stop | Out-Null
    $tot = 0; Get-ChildItem $script:CvOutbox -Filter *.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object { $tot += $_.Length }
    if ($tot -gt 60MB) { CvSay 'Outbox is full (60 MB): these pictures were NOT kept for later.' 'Yellow'; return $false }
    $b2 = $body.Clone(); $b2.Remove('key')   # the key is never written to disk
    $txt = ($b2 | ConvertTo-Json -Depth 6 -Compress)
    $dst = Join-Path $script:CvOutbox ('camviews-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    $tmp = $dst + '.tmp'
    try {
      [IO.File]::WriteAllText($tmp, $txt, (New-Object Text.UTF8Encoding($false)))
      if ([IO.File]::ReadAllText($tmp) -ne $txt) { throw 'the saved copy does not match' }
      [IO.File]::Move($tmp, $dst)
    } finally { if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch {} } }
    if ([IO.File]::ReadAllText($dst) -ne $txt) { throw 'the saved copy does not match' }
    return $true
  } catch { CvLog ('outbox save: ' + $_.Exception.Message); CvSay ('These pictures could NOT be kept in the outbox for later (' + $_.Exception.Message + ').') 'Yellow'; return $false }
}
# 2.2.19 (Codex 2.2.18 F25, class E): a waiting file that cannot be read, is not a camera-pictures push, or that the service refused is
# never deleted silently: it is moved to outbox\quarantine\<name>.<why>-<time> (kept as evidence), and the technician is told it was NOT
# sent. If even the move fails, the file stays where it is and is named again next time. Returns the new path, or '' when it stayed.
# $script:CvQuarantined lists what this run moved (or could not move), for the caller / the tests.
$script:CvQuarantined = @()
function Move-CvQuarantine([string]$Path, [string]$Why, [string]$Tag = 'corrupt') {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dest = ''
  try {
    $qd = Join-Path (Split-Path -Parent $Path) 'quarantine'
    New-Item -ItemType Directory -Force -Path $qd -ErrorAction Stop | Out-Null
    $d0 = Join-Path $qd ((Split-Path -Leaf $Path) + '.' + $Tag + '-' + $stamp)
    if (Test-Path -LiteralPath $d0) { $d0 = $d0 + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4) }
    Move-Item -LiteralPath $Path -Destination $d0 -ErrorAction Stop
    if ((Test-Path -LiteralPath $d0) -and -not (Test-Path -LiteralPath $Path)) { $dest = $d0 }
  } catch { CvLog ('quarantine: ' + $_.Exception.Message) }
  $script:CvQuarantined += [pscustomobject]@{ file = $Path; why = $Why; keptAs = $dest }
  return $dest
}
function Send-CvOutbox {
  if (-not (Test-Path $script:CvOutbox)) { return 0 }
  $key = Get-CvKey; if (-not $key) { return 0 }
  $sent = 0
  # 2.2.6 (Codex file-by-file A): the outbox is shared with the scan uploader (scan-*.json, op scanPush). Only this uploader's own files
  # (camviews-*.json) are read here; a waiting camera list is left for ScanUpload.ps1 (2.2.5 deleted it as "not a camera-pictures push").
  foreach ($f in @(Get-ChildItem $script:CvOutbox -Filter 'camviews-*.json' -File | Where-Object { $_.Name -like 'camviews-*.json' } | Sort-Object Name)) {
    $o = $null; $bad = ''
    try { $o = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $bad = 'it is damaged (' + $_.Exception.Message + ')' }
    # 2.2.3 (Codex #60): only a camera-pictures push leaves the outbox with the key, and only with its own fields (anything else is not sent)
    if (-not $bad -and (-not $o -or [string]$o.op -ne 'camPush')) { $bad = 'it is not a camera-pictures file' }
    if ($bad) {
      $kept = Move-CvQuarantine $f.FullName $bad 'corrupt'
      CvSay ('A waiting camera-pictures file (' + $f.Name + ') could not be used: ' + $bad + '. Those pictures were NOT sent. ' + $(if ($kept) { 'The file is kept as ' + $kept + '.' } else { 'It could not be moved aside, so it stays in the outbox.' })) 'Yellow'
      continue
    }
    $body = @{}; foreach ($p in @('op', 'site', 'source', 'pc', 'pics', 'complete')) { if ($o.PSObject.Properties[$p]) { $body[$p] = $o.$p } }; $body.key = $key
    $r = Send-CvBody $body
    if ($r -and $r.ok) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $sent++ }
    elseif ($r -and -not $r.ok -and $r.msg -notmatch '(?i)busy|too many') {
      $kept = Move-CvQuarantine $f.FullName ('refused: ' + [string]$r.msg) 'refused'
      CvSay ('Waiting pictures refused by the service log: ' + $r.msg + '. They were NOT sent. ' + $(if ($kept) { 'The file is kept as ' + $kept + '.' } else { 'It stays in the outbox.' })) 'Yellow'
    } else { break }
  }
  if ($sent) { CvSay ('Sent ' + $sent + ' waiting batch(es) of camera pictures.') 'Green' }
  return $sent
}
# 2.2.4: "A B", "A_B", "A/B" each get their own pictures folder: readable name + short fingerprint of the exact (case-folded) site name
function Get-CvSiteFolderName([string]$site) {
  $t = ([string]$site).Trim(); if (-not $t) { return 'no-site' }
  $safe = (($t -replace '[^A-Za-z0-9_-]+', '_').Trim('_')); if (-not $safe) { $safe = 'site' }; if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
  $sha = [Security.Cryptography.SHA256]::Create(); try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t.ToLowerInvariant())) } finally { $sha.Dispose() }
  return ($safe + '-' + (-join ($h[0..3] | ForEach-Object { $_.ToString('x2') })))
}
# 2.2.19 (Codex 2.2.18 F20, class F): returns { ok; why; path }. ok only when the picture file is written and reads back byte for byte.
# Older copies of the same camera are pruned only AFTER the new one is verified (a failed save never costs the last good picture).
function Save-CvLocal([string]$site, [string]$key, [string]$ip, [string]$stamp, $bytes) {
  $path = ''
  try {
    if (-not $bytes -or @($bytes).Count -eq 0) { throw 'no picture data' }
    $dir = Join-Path $script:CvPics (Get-CvSiteFolderName $site); New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    $path = Join-Path $dir ($key + '_' + $(if ($ip) { $ip } else { '-' }) + '_' + $stamp + '.jpg')
    [IO.File]::WriteAllBytes($path, [byte[]]$bytes)
    $back = [IO.File]::ReadAllBytes($path)
    if ($back.Length -ne @($bytes).Count -or [Convert]::ToBase64String($back) -ne [Convert]::ToBase64String([byte[]]$bytes)) { throw 'the saved picture does not read back the same' }
  } catch { CvLog ('local copy: ' + $_.Exception.Message); return [pscustomobject]@{ ok = $false; why = [string]$_.Exception.Message; path = $path } }
  try { Get-ChildItem -LiteralPath $dir -Filter ($key + '_*.jpg') | Sort-Object Name -Descending | Select-Object -Skip 2 | Remove-Item -Force -ErrorAction SilentlyContinue } catch { CvLog ('local prune: ' + $_.Exception.Message) }
  return [pscustomobject]@{ ok = $true; why = ''; path = $path }
}

# ---- the job ----
function Save-CameraViews {
  param([string]$Nvr, $Cred, [string]$Site, [string]$Vendor = 'auto', [int]$RecorderNo = 1, [switch]$NoUpload, $Channels = $null)
  # 2.2.19 (F20): pictures = pictures taken AND saved on this PC (verified); notSaved = taken but the PC copy failed (named with the reason)
  $cvr = [ordered]@{ ok = $false; pictures = 0; offline = @(); failed = @(); notSaved = @(); taken = 0; sent = $false; queued = $false; changed = @(); missing = @(); site = $Site }
  CvSay ''; CvSay '----- Camera pictures (last known view of each camera) -----' 'Cyan'
  if (-not $Nvr) { CvSay 'No NVR / camera address given.' 'Red'; return $cvr }
  if (-not $NoUpload) { try { [void](Send-CvOutbox) } catch { CvLog ('outbox: ' + $_.Exception.Message) } }
  if (-not $Site) { CvSay 'No site given (type the Site ID like WI-061 or the site folder name). Pictures are kept on this PC only.' 'Yellow' }
  $script:CvVendor = $(if ($Vendor -eq 'auto') { '' } else { $Vendor }); $script:CvLoginRefused = $false
  $chs = Get-CvChannels $Nvr $Cred $Vendor
  if ($script:CvLoginRefused) { CvSay ('The NVR at ' + $Nvr + ' refused the login. No pictures taken (and not retried, so nothing gets locked).') 'Red'; return $cvr }
  if (-not $chs.Count) { CvSay ('Could not read the camera list from ' + $Nvr + '.') 'Red'; return $cvr }
  CvSay ('Found ' + $chs.Count + ' camera' + $(if ($chs.Count -eq 1) { '' } else { 's' }) + ' on ' + $Nvr + ' (' + $script:CvVendor + '). Taking pictures...')
  $pics = New-Object System.Collections.Generic.List[object]
  $stampNow = Get-Date
  foreach ($ch in $chs) {
    $n = 0; [void][int]::TryParse(($ch.id -replace '\D', ''), [ref]$n); if ($n -lt 1) { continue }
    $key = $(if ($RecorderNo -gt 1) { 'R' + $RecorderNo + '-' } else { '' }) + 'CH' + $n.ToString('00')
    $label = 'CH ' + $n + $(if ($ch.ip) { ' (' + $ch.ip + ')' } else { '' })
    if ($ch.online -eq $false) { $cvr.offline += $label; CvSay ('  ' + $label + ': not answering - its last picture stays') 'Yellow'; $pics.Add(@{ key = $key; ip = $ch.ip; online = $false }); continue }
    $raw = Get-CvPicture $Nvr $Cred $ch
    if (-not $raw) { $cvr.failed += $label; CvSay ('  ' + $label + ': no picture came back') 'Yellow'; $pics.Add(@{ key = $key; ip = $ch.ip; online = $false }); continue }
    $p = Get-CvPrepared $raw
    if ($p.jpg.Length -gt 590000) { $cvr.failed += $label; CvSay ('  ' + $label + ': picture too big to send') 'Yellow'; continue }
    $taken = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    $sv = Save-CvLocal $Site $key $ch.ip ((Get-Date -Format 'yyyyMMdd-HHmm')) $p.jpg
    $e = @{ key = $key; ip = $ch.ip; taken = $taken; jpg = [Convert]::ToBase64String($p.jpg) }
    if ($p.sig) { $e.sig = $p.sig; $e.sh = $p.sh }
    $pics.Add($e); $cvr.taken++
    if ($sv.ok) { $cvr.pictures++; CvSay ('  ' + $label + ': picture ok (' + [int]($p.jpg.Length / 1024) + ' KB)') }
    else { $cvr.notSaved += $label; CvSay ('  ' + $label + ': picture taken, but it could NOT be saved on this PC (' + $sv.why + ')') 'Red' }
  }
  if ($cvr.notSaved.Count) { CvSay ('NOT saved on this PC: ' + $cvr.notSaved.Count + ' picture' + $(if ($cvr.notSaved.Count -eq 1) { '' } else { 's' }) + ' (folder ' + $script:CvPics + ').') 'Red' }
  if ($NoUpload -or -not $Site) {
    # 2.2.19 (F20): ok only for pictures that are really on this PC, and only when none failed to save
    if ($cvr.pictures -gt 0) { CvSay ('Pictures saved on this PC: ' + $cvr.pictures + ' in ' + $script:CvPics) }
    $cvr.ok = ($cvr.pictures -gt 0 -and -not $cvr.notSaved.Count); return $cvr
  }
  $key = Get-CvKey
  $withJpg = @($pics | Where-Object { $_.jpg }); $rest = @($pics | Where-Object { -not $_.jpg })
  $batches = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $withJpg.Count; $i += $script:CvBatch) { $batches.Add(@($withJpg[$i..([Math]::Min($i + $script:CvBatch, $withJpg.Count) - 1)])) }
  # last: the whole list (no pictures) marked complete, so the service log can tell a camera that is gone from the NVR
  $list = @($chs | ForEach-Object { $n = 0; [void][int]::TryParse(($_.id -replace '\D', ''), [ref]$n); if ($n -ge 1) { $k = $(if ($RecorderNo -gt 1) { 'R' + $RecorderNo + '-' } else { '' }) + 'CH' + $n.ToString('00'); $o = @{ key = $k; ip = $_.ip }; if ($_.online -eq $false) { $o.online = $false }; $o } })
  $okAll = $true
  $bodies = New-Object System.Collections.Generic.List[object]
  foreach ($b in $batches) { $bodies.Add(@{ op = 'camPush'; site = $Site; source = 'toolkit'; pc = $env:COMPUTERNAME; pics = $b }) }
  $bodies.Add(@{ op = 'camPush'; site = $Site; source = 'toolkit'; pc = $env:COMPUTERNAME; pics = $list; complete = $true })
  $keptAll = $true   # 2.2.19 (F20): "wait in the outbox" only when every batch really was kept there
  foreach ($body in $bodies) {
    if (-not $key) { if (-not (Save-CvOutbox $body)) { $keptAll = $false }; $okAll = $false; continue }
    $body.key = $key
    $r = $(if ($okAll) { Send-CvBody $body } else { $null })
    if ($r -and $r.ok) {
      if ($r.site) { $cvr.site = $r.site }
      foreach ($x in @($r.results)) { if ($x.changed) { $cvr.changed += ('CH ' + [int](($x.k -replace '^.*CH', '')) + ': looks ' + $x.changed) } }
      if ($body.complete) { $cvr.missing = @($r.missingKeys) }
    } elseif ($r -and -not $r.ok) { CvSay ('The service log refused the pictures: ' + $r.msg) 'Red'; $okAll = $false; if ($r.msg -match '(?i)site not found') { $keptAll = $false; break }; if (-not (Save-CvOutbox $body)) { $keptAll = $false } }
    else { $okAll = $false; if (-not (Save-CvOutbox $body)) { $keptAll = $false } }
  }
  $nTaken = $withJpg.Count
  if (-not $key) {
    if ($keptAll) { CvSay 'No upload key on this PC yet ("Set upload key.cmd"). Pictures wait in the outbox and go once the key is set.' 'Yellow'; $cvr.queued = $true }
    else { CvSay 'No upload key on this PC yet ("Set upload key.cmd"), and the pictures could NOT be kept in the outbox: they were not sent and will not go later.' 'Red' }
  }
  elseif ($okAll) { $cvr.sent = $true; CvSay ('Sent ' + $nTaken + ' picture' + $(if ($nTaken -eq 1) { '' } else { 's' }) + ' to the site page' + $(if ($cvr.site) { ' (' + $cvr.site + ')' } else { '' }) + '.') 'Green' }
  elseif ($keptAll) { $cvr.queued = $true; CvSay 'No internet / service log not reachable: pictures wait in the outbox and go next time the Toolkit runs.' 'Yellow' }
  else { CvSay 'The pictures were NOT sent and could NOT all be kept in the outbox: those will not go later.' 'Red' }
  foreach ($c in $cvr.changed) { CvSay ('  VIEW CHANGED? ' + $c) 'Yellow' }
  if ($cvr.missing.Count) { CvSay ('  MISSING compared with before: ' + ((@($cvr.missing) | ForEach-Object { $_ -replace '^CH0?', 'CH ' }) -join ', ')) 'Yellow' }
  # 2.2.19 (F20): ok = every picture taken is saved on this PC, and it is either sent or really kept in the outbox
  $cvr.ok = ($cvr.pictures -gt 0 -and -not $cvr.notSaved.Count -and ($cvr.sent -or $cvr.queued))
  return $cvr
}

# ---- automatic refresh on a PC that stays on the site's network (daily task, hidden) ----
# 2.2.5 fix 10: Windows PowerShell 5.1's ConvertFrom-Json writes a JSON array as ONE object, so @(text | ConvertFrom-Json) was a 1-item
# array there: with 2 or more remembered NVRs Get-CvSites gave ONE "site" whose .nvr was "10.0.0.1 10.0.0.2", the daily refresh found no
# login for it and skipped every NVR, and the next -Remember wrote [{"value":[...],"Count":2},{...}] (seen on the Office PC, Nov 8 2026).
# Parsed into a variable first, then unrolled, it is the real list on 5.1 and 7 alike (same as FixSiteBw's ConvertFrom-FsJsonArray).
# A list a 5.1 save already wrote that way ({"value":[...],"Count":n} in place of its sites, or nested lists) reads back as its sites.
function Expand-CvSiteItem($i) {
  if ($null -eq $i) { return }
  if ($i -is [array]) { foreach ($j in $i) { Expand-CvSiteItem $j }; return }
  if ($i.PSObject.Properties['value'] -and -not $i.PSObject.Properties['nvr']) { foreach ($j in @($i.value)) { Expand-CvSiteItem $j }; return }
  $i
}
function ConvertFrom-CvJsonArray([string]$text) {
  if (-not $text -or -not $text.Trim()) { return }
  $v = ConvertFrom-Json -InputObject $text
  foreach ($i in $v) { Expand-CvSiteItem $i }
}
function Get-CvSites { $p = Join-Path $script:CvHere 'camviews-sites.json'; if (-not (Test-Path -LiteralPath $p)) { return @() }; return @(ConvertFrom-CvJsonArray (Get-Content -LiteralPath $p -Raw)) }
# 2.2.1 (review M2): a remembered NVR login is machine-wide DPAPI (the daily task runs as SYSTEM), so anyone who can READ the file can
# decrypt it on this PC. It now lives in vault\ (Administrators + SYSTEM only, set by the installer) AND the file itself gets its own
# Administrators + SYSTEM-only permissions when it is written - it is never left behind readable: if that fails it is deleted.
$script:CvDpapi = $null    # TESTS ONLY: { param([string]$op, [byte[]]$data) } stands in for DPAPI
$script:CvAclRun = $null   # TESTS ONLY: { param([string[]]$icaclsArgs) -> exit code }
function Invoke-CvDpapi([string]$op, [byte[]]$data) {
  if ($script:CvDpapi) { return [byte[]](& $script:CvDpapi $op $data) }
  Add-Type -AssemblyName System.Security
  $ent = [Text.Encoding]::ASCII.GetBytes('WireIt-Toolkit-nvr-v1')
  if ($op -eq 'protect') { return [Security.Cryptography.ProtectedData]::Protect($data, $ent, [Security.Cryptography.DataProtectionScope]::LocalMachine) }
  return [Security.Cryptography.ProtectedData]::Unprotect($data, $ent, [Security.Cryptography.DataProtectionScope]::LocalMachine)
}
# 2.2.5: + the Windows login that saves it (when it is not SYSTEM). A non-elevated admin's token has Administrators as deny-only, so
# with Admins + SYSTEM alone the file it had just written and locked could no longer be moved or read by it ("Access to the path is
# denied" at the Move-Item, seen on the Office PC Nov 8 2026). Other logins (a non-admin) still cannot read it.
function Get-CvSaverSid { if ($env:OS -ne 'Windows_NT') { return '' }; try { $v = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; if ($v -and $v -notin @('S-1-5-18', 'S-1-5-32-544')) { return $v } } catch {}; return '' }
function Get-CvPrivateAclArgs([string]$path) { $a = @($path, '/inheritance:r', '/grant:r', '*S-1-5-32-544:F', '*S-1-5-18:F'); $me = Get-CvSaverSid; if ($me) { $a += ('*' + $me + ':F') }; return $a }
# 2.2.5: the locked temp file goes into place with retries (an antivirus or the indexer can hold a new file for a moment), then
# copy + delete as the last way; the temp file is never left behind.
function Move-CvIntoPlace([string]$src, [string]$dst) {
  $last = $null
  for ($i = 0; $i -lt 4; $i++) {
    try { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; return } catch { $last = $_.Exception.Message; Start-Sleep -Milliseconds (150 * ($i + 1)) }
  }
  try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue; return } catch { $last = $_.Exception.Message }
  Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
  throw ('the NVR login was NOT remembered: its file could not be put in place (' + $last + '). Run the Toolkit as an admin and try again.')
}
function Set-CvPrivateFile([string]$path) {
  $a = Get-CvPrivateAclArgs $path
  if ($script:CvAclRun) { return ([int](& $script:CvAclRun $a) -eq 0) }
  try { $null = & icacls.exe @a 2>&1; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
function Get-CvCredFile([string]$nvr, [switch]$Legacy) { return (Join-Path (Join-Path $script:CvHere $(if ($Legacy) { 'secrets' } else { 'vault' })) ('nvr-' + ($nvr -replace '[^0-9A-Za-z.]', '_') + '.bin')) }
function Save-CvSite([string]$nvr, [string]$site, [string]$user, [string]$vendor, [int]$rec, $pw) {
  $f = Get-CvCredFile $nvr; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
  $b = Invoke-CvDpapi 'protect' ([Text.Encoding]::UTF8.GetBytes((@{ user = $user; pw = $plain } | ConvertTo-Json -Compress)))
  $plain = $null
  $tmp = $f + '.' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.tmp'   # 2.2.5: a unique temp name (a stale locked .tmp from another run never blocks this one)
  # 2.2.7 (Codex file-by-file F08): the file is created EMPTY and locked first, and only then gets the login. 2.2.6 wrote the encrypted
  # login and locked it afterwards: for that moment (or for good, if the lock then failed and the delete did too) anyone who could
  # read the folder could read the file - and machine-wide DPAPI lets any login on this PC decrypt it.
  [IO.File]::WriteAllBytes($tmp, [byte[]]@())
  if (-not (Set-CvPrivateFile $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw 'the NVR login was NOT remembered: its file could not be locked to Administrators (run it as an admin)' }
  try { [IO.File]::WriteAllBytes($tmp, $b) } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw ('the NVR login was NOT remembered: ' + $_.Exception.Message) }
  Move-CvIntoPlace $tmp $f
  $lf = Get-CvCredFile $nvr -Legacy; if (Test-Path -LiteralPath $lf) { Remove-Item -LiteralPath $lf -Force -ErrorAction SilentlyContinue }   # the 2.2.0 copy in secrets\ (Crew could read that folder)
  $list = @(Get-CvSites | Where-Object { $_.nvr -ne $nvr }) + @([pscustomobject]@{ nvr = $nvr; site = $site; vendor = $vendor; recorder = $rec })
  # 2.2.5 fix 10: one flat entry per NVR, written as a plain array (never a list inside the list)
  $flat = [object[]]@(foreach ($e in $list) { [pscustomobject][ordered]@{ nvr = [string]$e.nvr; site = [string]$e.site; vendor = [string]$e.vendor; recorder = $(if ($e.recorder) { [int]$e.recorder } else { 1 }) } })
  # 2.2.20 (Codex 2.2.19 class A, second pass): the site list counts as saved only when it reads back with this NVR on it; else THROW
  # (2.2.19 wrote it with Set-Content under the caller's preference, and "Remembered" was said even when the write was refused)
  $sp = Join-Path $script:CvHere 'camviews-sites.json'; $sj = [string](ConvertTo-Json -InputObject $flat -Depth 3); $stmp = $sp + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
  try {
    [IO.File]::WriteAllText($stmp, $sj, (New-Object Text.UTF8Encoding($true)))
    # .NET swap, not Move-Item (2.2.5: Move-Item can be refused on an Office PC run without admin rights)
    if ([IO.File]::Exists($sp)) { [IO.File]::Replace($stmp, $sp, [NullString]::Value) } else { [IO.File]::Move($stmp, $sp) }
    $back = @(Get-CvSites); if (-not @($back | Where-Object { [string]$_.nvr -eq $nvr -and [string]$_.site -eq $site }).Count -or $back.Count -ne $flat.Count) { throw 'it does not read back as written' }
  } catch { throw ('the NVR login was saved, but the site list (camviews-sites.json) was NOT: ' + $_.Exception.Message) }
  finally { if (Test-Path -LiteralPath $stmp) { Remove-Item -LiteralPath $stmp -Force -ErrorAction SilentlyContinue } }
}
function Get-CvSiteCred([string]$nvr) {
  $f = Get-CvCredFile $nvr; $legacy = $false
  if (-not (Test-Path -LiteralPath $f)) { $f = Get-CvCredFile $nvr -Legacy; $legacy = $true; if (-not (Test-Path -LiteralPath $f)) { return $null } }
  $o = [Text.Encoding]::UTF8.GetString((Invoke-CvDpapi 'unprotect' ([IO.File]::ReadAllBytes($f)))) | ConvertFrom-Json
  $cred = New-Object System.Management.Automation.PSCredential ($o.user, (ConvertTo-SecureString $o.pw -AsPlainText -Force))
  if ($legacy) {
    # moved into vault\ (locked) the first time an admin or the SYSTEM task reads it; the readable copy is then deleted
    try { $site = @(Get-CvSites | Where-Object { $_.nvr -eq $nvr })[0]; Save-CvSite $nvr $(if ($site) { [string]$site.site } else { '' }) $o.user $(if ($site) { [string]$site.vendor } else { 'auto' }) $(if ($site -and $site.recorder) { [int]$site.recorder } else { 1 }) $cred.Password } catch {}
  }
  return $cred
}
function Invoke-CvAuto {
  $sites = @(Get-CvSites)
  if (-not $sites.Count) { CvSay 'No NVR remembered on this PC (CamViews.ps1 -Nvr <ip> -Site <WI-###> -Remember).'; return }
  foreach ($s in $sites) {
    $cred = Get-CvSiteCred $s.nvr
    if (-not $cred) { CvSay ('No saved login for ' + $s.nvr); continue }
    [void](Save-CameraViews -Nvr $s.nvr -Cred $cred -Site $s.site -Vendor $(if ($s.vendor) { $s.vendor } else { 'auto' }) -RecorderNo $(if ($s.recorder) { [int]$s.recorder } else { 1 }))
    $cred = $null
  }
}
function Install-CvTask {
  $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $a = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $script:CvHere 'CamViews.ps1') + '" -Auto')
  $t = New-ScheduledTaskTrigger -Daily -At '12:30'
  $st = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'WireIt Camera Pictures' -Action $a -Trigger $t -Settings $st -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
  CvSay 'Daily camera pictures set up (12:30, hidden, task "WireIt Camera Pictures"). Remove with CamViews.ps1 -RemoveTask.' 'Green'
}

if ($Lib) { return }
if ($SetKey) { Set-CvKey; exit 0 }
if ($Auto) { Invoke-CvAuto; exit 0 }
if ($InstallTask) { Install-CvTask; exit 0 }
if ($RemoveTask) { Unregister-ScheduledTask -TaskName 'WireIt Camera Pictures' -Confirm:$false -ErrorAction SilentlyContinue; CvSay 'Daily camera pictures task removed.'; exit 0 }
if ($PrepDir) {
  foreach ($f in @(Get-ChildItem -LiteralPath $PrepDir -Filter *.jpg -File)) {
    try {
      $b = [IO.File]::ReadAllBytes($f.FullName); $p = Get-CvPrepared $b
      if ($p.jpg.Length -ne $b.Length) { [IO.File]::WriteAllBytes($f.FullName, $p.jpg) }
      Write-Output (@{ name = $f.Name; sig = $p.sig; sh = $p.sh; bytes = $p.jpg.Length } | ConvertTo-Json -Compress)
    } catch { Write-Output (@{ name = $f.Name; err = $_.Exception.Message } | ConvertTo-Json -Compress) }
  }
  exit 0
}
if ($SendOutbox) { [void](Send-CvOutbox); exit 0 }
if (-not $Nvr) { $Nvr = Read-Host 'NVR (or camera) address, e.g. 192.168.1.20' }
if (-not $Site) { $Site = Read-Host 'Site ID (WI-###) or the site folder name' }
$cred = $null
if ($CredFile) { $l = Get-Content $CredFile; $cred = New-Object System.Management.Automation.PSCredential ($l[0], (ConvertTo-SecureString $l[1] -AsPlainText -Force)) }
else { $pw = Read-Host ('Password for ' + $User + ' on ' + $Nvr + ' (hidden, not saved)') -AsSecureString; $cred = New-Object System.Management.Automation.PSCredential ($User, $pw) }
if ($Remember) { try { Save-CvSite $Nvr $Site $cred.UserName $Vendor $RecorderNo $cred.Password; CvSay ('Remembered ' + $Nvr + ' for ' + $Site + ' (login encrypted for this PC only, readable by Administrators only). Run CamViews.ps1 -InstallTask for a daily refresh.') 'Green' } catch { CvSay ([string]$_.Exception.Message) 'Red' } }
$res = Save-CameraViews -Nvr $Nvr -Cred $cred -Site $Site -Vendor $Vendor -RecorderNo $RecorderNo -NoUpload:$NoUpload
$cred = $null
if ($res.ok) { exit 0 } else { exit 3 }
