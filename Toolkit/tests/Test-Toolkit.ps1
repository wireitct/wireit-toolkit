<#
 Test-Toolkit.ps1 - checks for the WireIt Toolkit (Windows PowerShell 5.1). Touches no device and opens no window on screen.
 Usage: powershell -ExecutionPolicy Bypass -File tests\Test-Toolkit.ps1 [-Root C:\WireIt] [-Screens <folder>]
#>
param([string]$Root = '', [string]$Screens = '')
$ErrorActionPreference = 'Stop'
$tkDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Root) { $Root = Split-Path -Parent $tkDir }
. (Join-Path $tkDir 'ToolkitCore.ps1')
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok, [string]$info = '') { if ($ok) { $script:pass++; Write-Output ('PASS ' + $name) } else { $script:fail++; Write-Output ('FAIL ' + $name + '  ' + $info) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-tktest-' + (Get-Random)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# 1 parse every script (Toolkit + the tools it runs)
$scripts = @(Get-ChildItem $tkDir -Filter *.ps1 -File -Recurse) + @(foreach ($t in 'FixNVR\FixNVR.ps1', 'CamReset\Find-Cameras.ps1', 'CamReset\Make-Request.ps1', 'CamReset\Install-CamReset.ps1', 'NetCheck\NetCheck.ps1') { $p = Join-Path $Root $t; if (Test-Path $p) { Get-Item $p } })
foreach ($s in $scripts) { $tok = $null; $err = $null; [void][Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$tok, [ref]$err); Check ('parse ' + $s.Name) ($err.Count -eq 0) (($err | Select-Object -First 2 | ForEach-Object { $_.Message + ' line ' + $_.Extent.StartLineNumber }) -join '; ') }

# 2 versions + manifest rules
Check 'version 1.0.10 > 1.0.9' ((Compare-TkVersion '1.0.10' '1.0.9') -eq 1)
Check 'version equal' ((Compare-TkVersion '1.2' '1.2.0') -eq 0)
Check 'version older' ((Compare-TkVersion '0.9.9' '1.0.0') -eq -1)
Check 'path ok' (Test-TkManifestPath 'FixNVR/FixNVR.ps1')
Check 'path ..' (-not (Test-TkManifestPath 'Toolkit/../x.ps1'))
Check 'path absolute' (-not (Test-TkManifestPath 'C:/Windows/x.ps1'))
Check 'path config.json blocked' (-not (Test-TkManifestPath 'CamReset/config.json'))
Check 'path other folder blocked' (-not (Test-TkManifestPath 'Windows/x.ps1'))
$good = [pscustomobject]@{ version = '9.9.9'; base = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/abc/'; files = @([pscustomobject]@{ path = 'Toolkit/a.ps1'; sha256 = ('a' * 64) }) }
Check 'manifest ok' ((Test-TkManifest $good) -eq '')
$evil = [pscustomobject]@{ version = '9.9.9'; base = 'https://evil.example.com/'; files = $good.files }
Check 'manifest other site refused' ((Test-TkManifest $evil) -ne '')

# 3 passwords
$pws = 1..200 | ForEach-Object { New-TkPassword 14 }
$okAll = $true; foreach ($p in $pws) { if ($p.Length -ne 14 -or $p -cnotmatch '[A-Z]' -or $p -cnotmatch '[a-z]' -or $p -notmatch '\d' -or $p -notmatch '[#@!%*+=?]' -or $p -match '(?i)admin' -or $p -cmatch '[O0Il1]') { $okAll = $false; $bad = $p } }
Check 'passwords strong (200)' $okAll $bad
Check 'passwords unique' (@($pws | Select-Object -Unique).Count -eq 200)
Check 'password length clamp' ((New-TkPassword 40).Length -eq 16)
Check 'short serial camera' ((Get-TkShortSerial 'DS-2CD2143G2-I20210101AAWRF12345678') -eq 'F12345678')
Check 'short serial NVR (WCVU suffix)' ((Get-TkShortSerial 'DS-7608NI-K2/8P0820210101CCRRJ12345678WCVU') -eq 'J12345678')
Check 'short serial new style' ((Get-TkShortSerial 'DS-2CD2387G2-LU20230119AAWRAF1234567') -eq 'AF1234567')

# 4 update: install, bad hash, undo, offline
$w = Join-Path $tmp 'WireIt'; $tk = Join-Path $w 'Toolkit'
New-Item -ItemType Directory -Force -Path $tk, (Join-Path $w 'FixNVR') | Out-Null
Set-Content (Join-Path $tk 'a.ps1') 'old a'; Set-Content (Join-Path $w 'FixNVR\FixNVR.ps1') 'old fix'; Set-Content (Join-Path $w 'FixNVR\config.json') '{"keep":1}'
Save-TkJson ([ordered]@{ version = '1.0.0' }) (Join-Path $tk 'version.json')
$store = @{ 'Toolkit/a.ps1' = [Text.Encoding]::UTF8.GetBytes('new a'); 'FixNVR/FixNVR.ps1' = [Text.Encoding]::UTF8.GetBytes('new fix'); 'NetCheck/NetCheck.ps1' = [Text.Encoding]::UTF8.GetBytes('net') }
$fl = foreach ($k in $store.Keys) { $f = Join-Path $tmp 'h.bin'; [IO.File]::WriteAllBytes($f, $store[$k]); [pscustomobject]@{ path = $k; sha256 = (Get-TkSha256 $f) } }
$m = [pscustomobject]@{ version = '1.1.0'; released = '2026-11-02'; commit = 'test'; base = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/test/'; files = @($fl) }
$fetch = { param($url) $k = ($url -replace '^https://raw.githubusercontent.com/wireitct/wireit-toolkit/test/', ''); $k = [Uri]::UnescapeDataString($k); return $store[$k] }
$badM = [pscustomobject]@{ version = '1.1.0'; base = $m.base; files = @([pscustomobject]@{ path = 'Toolkit/a.ps1'; sha256 = ('0' * 64) }) }
$threw = $false; try { Install-TkUpdate $badM $tk $fetch | Out-Null } catch { $threw = $true }
Check 'bad hash refused' ($threw -and ((Get-Content (Join-Path $tk 'a.ps1') -Raw).Trim() -eq 'old a') -and ((Get-TkVersion $tk) -eq '1.0.0'))
$old = Install-TkUpdate $m $tk $fetch
Check 'update installed' (((Get-Content (Join-Path $tk 'a.ps1') -Raw).Trim() -eq 'new a') -and ((Get-Content (Join-Path $w 'FixNVR\FixNVR.ps1') -Raw).Trim() -eq 'new fix') -and (Test-Path (Join-Path $w 'NetCheck\NetCheck.ps1')))
Check 'update version' ((Get-TkVersion $tk) -eq '1.1.0' -and $old -eq '1.0.0')
Check 'config untouched' ((Get-Content (Join-Path $w 'FixNVR\config.json') -Raw).Trim() -eq '{"keep":1}')
Check 'previous kept' (Test-Path (Join-Path $tk 'previous\1.0.0\FixNVR\FixNVR.ps1'))
$back = Undo-TkUpdate $tk
Check 'undo restores files' (((Get-Content (Join-Path $tk 'a.ps1') -Raw).Trim() -eq 'old a') -and ((Get-Content (Join-Path $w 'FixNVR\FixNVR.ps1') -Raw).Trim() -eq 'old fix'))
Check 'undo removes added file' (-not (Test-Path (Join-Path $w 'NetCheck\NetCheck.ps1')))
Check 'undo version + skip' ($back -eq '1.0.0' -and (Get-TkVersion $tk) -eq '1.0.0' -and (Get-TkSkipVersion $tk) -eq '1.1.0')
$sw = [Diagnostics.Stopwatch]::StartNew()
$off = Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = 'http://127.0.0.1:9/version.json'; updateTimeoutMs = 3000 }) $tk
Check 'offline = just run' ($off.state -eq 'offline' -and $sw.ElapsedMilliseconds -lt 6000) ($off.state + ' ' + $sw.ElapsedMilliseconds)
$mf = Join-Path $tmp 'version.json'; ($m | ConvertTo-Json -Depth 5) | Set-Content $mf -Encoding UTF8
$av = Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = ([Uri]$mf).AbsoluteUri; updateTimeoutMs = 3000 }) $tk
Check 'newer version seen' ($av.state -eq 'available') $av.message
$mf2 = Join-Path $tmp 'evil.json'; ($evil | ConvertTo-Json -Depth 5) | Set-Content $mf2 -Encoding UTF8
$ev = Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = ([Uri]$mf2).AbsoluteUri; updateTimeoutMs = 3000 }) $tk
Check 'foreign download refused' ($ev.state -eq 'error') $ev.message
if ($env:WIREIT_LIVE_URL) { $lv = Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = $env:WIREIT_LIVE_URL; updateTimeoutMs = 8000 }) $tk; Check 'live version.json readable' ($lv.state -in @('available', 'current')) $lv.message }

# 5 reset flow with the real CamReset scripts against a fake scan (no network)
$cr = Join-Path $tmp 'CamReset'; New-Item -ItemType Directory -Force -Path (Join-Path $cr 'out'), (Join-Path $cr 'requests\export') | Out-Null
$devs = @([ordered]@{ Brand = 'Hikvision'; Model = 'DS-7608NI-K2/8P'; Serial = 'DS-7608NI-K2/8P0820210101CCRRJ12345678WCVU'; IP = '192.168.1.64'; MAC = 'C4-2F-90-AA-00-01'; StartTime = '2026-11-01 03:00:00'; Activated = 'true'; Status = 'Activated (password unknown?)'; NextStep = 'x' },
          [ordered]@{ Brand = 'Hikvision'; Model = 'DS-2CD2143G2-I'; Serial = 'DS-2CD2143G2-I20220101AAWRK87654321'; IP = '192.168.1.65'; MAC = 'C4-2F-90-AA-00-02'; StartTime = ''; Activated = 'false'; Status = 'NOT ACTIVATED (factory fresh)'; NextStep = 'x' })
([ordered]@{ scannedAt = (Get-Date -Format 's'); pc = 'TEST'; folder = ''; devices = $devs } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $cr 'out\latest.json') -Encoding UTF8
$d = @(Get-TkDevices $cr)
Check 'devices read' ($d.Count -eq 2 -and $d[0].ShortSerial -eq 'J12345678') ($d | Out-String)
$fields = Get-TkFormFields (Get-TkConfig $tk) $d[0]
Check 'form fields' ((($fields | Where-Object Label -eq 'Serial (9)').Value -eq 'J12345678') -and (($fields | Where-Object Label -eq 'Email').Value -eq 'moshe@wireitct.com') -and $fields.Count -eq 9)
$mr = Join-Path $Root 'CamReset\Make-Request.ps1'
if (Test-Path $mr) {
  Copy-Item $mr $cr
  $xml = Join-Path $cr 'requests\export\DS-7608NI-K2_J12345678.xml'; Set-Content $xml '<?xml version="1.0"?><ResetPasswordExport><serialNumber>J12345678</serialNumber></ResetPasswordExport>'
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cr 'Make-Request.ps1') -XmlPath $xml -Serial J12345678 2>&1 | Out-String
  $reqs = @(Get-TkRequests $cr)
  Check 'Make-Request filed it' ($reqs.Count -eq 1 -and $reqs[0].shortSerial -eq 'J12345678') $o
  $hl = Get-TkHoursLeft $reqs[0]; Check 'request 48 h window' ($hl -gt 47 -and $hl -le 48) ([string]$hl)
  Check 'export watcher sees file' (@(Find-TkNewXml @((Join-Path $cr 'requests\export')) (Get-Date).AddMinutes(-5)).Count -eq 1)
  $reply = Join-Path $tmp 'Encrypt.xml'; Set-Content $reply '<Encrypt><sn>DS-7608NI-K2/8P0820210101CCRRJ12345678WCVU</sn><key>ABC</key></Encrypt>'
  $r = Import-TkReply $reply $cr
  Check 'reply matched by serial' ($r.ok -and $r.request -and $r.serial -like '*J12345678*' -and (Test-Path $r.file)) $r.message
  $after = @(Get-TkRequests $cr)[0]
  Check 'request marked reply received' ($after.status -eq 'reply received' -and $after.replyFile -eq $r.file)
  $zdir = Join-Path $tmp 'z'; New-Item -ItemType Directory -Force -Path $zdir | Out-Null; Set-Content (Join-Path $zdir 'J12345678_key.xml') '<k/>'
  $zip = Join-Path $tmp 'reply.zip'; Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory($zdir, $zip)
  $rz = Import-TkReply $zip $cr
  Check 'zip reply unpacked + matched' ($rz.ok -and $rz.request -and $rz.file -like '*J12345678_key.xml') $rz.message
} else { Check 'Make-Request.ps1 present' $false $mr }
$un = Join-Path $tmp 'other.xml'; Set-Content $un '<x/>'
$cr2 = Join-Path $tmp 'CamReset2'; New-Item -ItemType Directory -Force -Path $cr2 | Out-Null
$ru = Import-TkReply $un $cr2
Check 'unmatched reply still saved, says so' ($ru.ok -and -not $ru.request -and $ru.message -like '*did not match*')

# 6 Fix NVR run folders + log reading
$fx = Join-Path $tmp 'FixNVR'; $rd = Join-Path $fx 'runs\Fix-20261102-101500'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
Set-Content (Join-Path $rd 'rollback.json') '{}'
Check 'last fix found' ((Get-TkLastFix $fx).File -eq (Join-Path $rd 'rollback.json'))
$since = Get-Date; Start-Sleep -Milliseconds 50; $nd = Join-Path $fx ('runs\Check-' + (Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item -ItemType Directory -Force -Path $nd | Out-Null
Check 'new run folder found' ((Get-TkNewRunDir $fx 'Check' $since).FullName -eq $nd)
$said = ConvertFrom-TkFixLog @('10:00:01 start mode=Check', '10:00:02 SAY This PC: 10.0.0.50/24', '10:00:03 SAY ', '10:00:04 HTTP GET x')
Check 'log -> plain lines' ($said.Count -eq 2 -and $said[0] -eq 'This PC: 10.0.0.50/24')
$lf = Join-Path $tmp 'grow.txt'; [IO.File]::WriteAllText($lf, "line1`nhalf")
$x = Read-TkShared $lf 0 ([Text.Encoding]::UTF8); Check 'tail keeps half lines' ($x.text -eq "line1`n" -and $x.offset -eq 6)
[IO.File]::AppendAllText($lf, "-done`n"); $x2 = Read-TkShared $lf $x.offset ([Text.Encoding]::UTF8); Check 'tail continues' ($x2.text -eq "half-done`n")

# 7 hidden runner: output + exit code come back, no window
$probe = Join-Path $tmp 'probe.ps1'; Set-Content $probe "Write-Host 'hello from tool'; Write-Output ('arg=' + `$args[0]); exit 3"
$of = Join-Path $tmp 'probe-out.txt'
$psi = New-TkHiddenPsi (Join-Path $PSHOME 'powershell.exe') $probe '"two words"' $of
$pr = [Diagnostics.Process]::Start($psi); [void]$pr.WaitForExit(60000)
$txt = Get-Content $of -Raw
Check 'hidden run output' ($txt -match 'hello from tool' -and $txt -match 'arg=two words') $txt
Check 'hidden run exit code' ($pr.ExitCode -eq 3) ([string]$pr.ExitCode)
Check 'plain end text' ((Get-TkPlainEnd 'Fix NVR' 4) -like '*Undo*')
$lp = Write-TkLog (Join-Path $tmp 'logs') 'Find cameras' 'x'; Check 'log written' ((Test-Path $lp) -and $lp -like '*_Find-cameras.txt')

# 9 camera pictures (CamViews.ps1): shrink + view signature on Windows' own System.Drawing; key handling
. (Join-Path $tkDir 'CamViews.ps1') -Lib
Add-Type -AssemblyName System.Drawing
function New-TestJpeg([int]$w, [int]$h, [bool]$flat) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h; $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::FromArgb(90, 110, 130))
  if (-not $flat) { $rnd = New-Object Random 7; for ($i = 0; $i -lt 60; $i++) { $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($rnd.Next(256), $rnd.Next(256), $rnd.Next(256))); $g.FillRectangle($br, $rnd.Next($w), $rnd.Next($h), $rnd.Next(40, 300), $rnd.Next(20, 200)); $br.Dispose() } }
  $g.Dispose(); $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose(); return ,$ms.ToArray()
}
$big = New-TestJpeg 1920 1080 $false
$pp = Get-CvPrepared $big
$im = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $pp.jpg)))
Check 'pictures: 1080p shrunk to 640 wide JPEG' ($im.Width -eq 640 -and $im.Height -eq 360 -and $pp.jpg[0] -eq 0xFF -and $pp.jpg[1] -eq 0xD8 -and $pp.jpg.Length -lt 150000) ([string]$im.Width + 'x' + $im.Height + ' ' + $pp.jpg.Length)
$im.Dispose()
Check 'pictures: signature 64x36 gray (2304 bytes)' ([Convert]::FromBase64String($pp.sig).Length -eq 2304)
$flat = Get-CvPrepared (New-TestJpeg 1280 720 $true)
Check 'pictures: sharpness measured (busy scene > flat covered scene)' ($pp.sh -gt 0 -and $flat.sh -lt $pp.sh) ([string]$pp.sh + ' / ' + [string]$flat.sh)
$again = Get-CvPrepared $big
Check 'pictures: same picture -> same signature' ($again.sig -eq $pp.sig)
$small = New-TestJpeg 320 180 $false; $ps2 = Get-CvPrepared $small
Check 'pictures: small picture left as is' ($ps2.jpg.Length -eq $small.Length)
Check 'pictures: not a JPEG refused' (-not (CvIsJpeg ([Text.Encoding]::ASCII.GetBytes('<html>not a picture</html>' + (' ' * 300)))))
# key: DPAPI round trip, this PC only; outbox never stores it
$script:CvHere = $tmp; New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'secrets') | Out-Null
Add-Type -AssemblyName System.Security
$kb = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes('{"key":"abcdefghijklmnopqrstuvwxyz012345"}'), [Text.Encoding]::ASCII.GetBytes('WireIt-Toolkit-v1'), [Security.Cryptography.DataProtectionScope]::LocalMachine)
[IO.File]::WriteAllBytes((Join-Path $tmp 'secrets\upload-key.bin'), $kb)
$envk = $env:WIREIT_UPLOAD_KEY; $env:WIREIT_UPLOAD_KEY = ''
Check 'pictures: upload key read back (DPAPI, this PC)' ((Get-CvKey) -eq 'abcdefghijklmnopqrstuvwxyz012345')
Check 'pictures: key file is not plain text' (-not ([Text.Encoding]::UTF8.GetString($kb) -match 'abcdefghij'))
$env:WIREIT_UPLOAD_KEY = $envk
$script:CvOutbox = Join-Path $tmp 'outbox'
Save-CvOutbox @{ op = 'camPush'; key = 'abcdefghijklmnopqrstuvwxyz012345'; site = 'WI-TEST'; pics = @(@{ key = 'CH01'; ip = '10.0.0.21' }) }
$of = @(Get-ChildItem $script:CvOutbox -Filter *.json)
Save-CvSite '10.9.9.20' 'WI-TEST' 'admin' 'hik' 1 (ConvertTo-SecureString 'NvrPw#123' -AsPlainText -Force)
$sc = Get-CvSiteCred '10.9.9.20'
Check 'pictures: remembered NVR login round trip (DPAPI), not in the list file' ($sc.UserName -eq 'admin' -and $sc.GetNetworkCredential().Password -eq 'NvrPw#123' -and (Get-Content (Join-Path $tmp 'camviews-sites.json') -Raw) -notmatch 'NvrPw' -and @(Get-CvSites).Count -eq 1 -and (Get-CvSites)[0].site -eq 'WI-TEST')
Check 'pictures: outbox file written without the key' ($of.Count -eq 1 -and (Get-Content $of[0].FullName -Raw) -notmatch 'abcdefghij' -and (Get-Content $of[0].FullName -Raw) -match 'WI-TEST')

# 8 the window itself, drawn off-screen to PNG (no window on the desktop)
if ($Screens) {
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $tkDir 'WireItToolkit.ps1') -Screenshot $Screens -DemoCamReset $cr 2>&1 | Out-String
  Check 'window builds (8 buttons)' ($o -match 'buttons=8') $o
  Check 'screenshots saved' ((Test-Path (Join-Path $Screens 'toolkit-main.png')) -and (Test-Path (Join-Path $Screens 'toolkit-reset.png'))) $o
  Check 'new look built (rounded cards, header)' ($o -match 'look=new') $o
  Check 'icon font found' ($o -match 'icons=Segoe') $o
  $s150 = Join-Path $Screens 'at150'
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $tkDir 'WireItToolkit.ps1') -Screenshot $s150 -SimScale 1.5 -DemoCamReset $cr 2>&1 | Out-String
  Check 'window builds at 150% (the Dell screen)' (($o -match 'buttons=8') -and ($o -match 'scale=1.5') -and (Test-Path (Join-Path $s150 'toolkit-main.png'))) $o
}
Check 'logo file present' (Test-Path (Join-Path $tkDir 'wireit-logo.png'))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('RESULT ' + $script:pass + ' passed, ' + $script:fail + ' failed')
if ($script:fail) { exit 1 }
