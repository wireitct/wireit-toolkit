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
$nb = $(if (Test-Path (Join-Path $tkDir 'FixIt.ps1')) { 15 } else { 14 })   # 1.6.0 adds 'Fix what failed'
function Check([string]$name, [bool]$ok, [string]$info = '') { if ($ok) { $script:pass++; Write-Output ('PASS ' + $name) } else { $script:fail++; Write-Output ('FAIL ' + $name + '  ' + $info) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-tktest-' + (Get-Random)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# 1 parse every script (Toolkit + the tools it runs)
$scripts = @(Get-ChildItem $tkDir -Include *.ps1, *.psm1 -File -Recurse) + @(foreach ($t in 'FixNVR\FixNVR.ps1', 'CamReset\Find-Cameras.ps1', 'CamReset\Make-Request.ps1', 'CamReset\Install-CamReset.ps1', 'NetCheck\NetCheck.ps1') { $p = Join-Path $Root $t; if (Test-Path $p) { Get-Item $p } })
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

# 7b recorder health (buttons 9-12: NvrHealth module + NvrCheck.ps1) - mock recorders only, no real device
$nm = Join-Path $tkDir 'modules\NvrHealth\NvrHealth.psm1'
Check 'NvrHealth module present' (Test-Path $nm)
Check 'NvrHealth firmware list present' (Test-Path (Join-Path $tkDir 'modules\NvrHealth\firmware-latest.json'))
Check 'path modules/NvrHealth allowed' (Test-TkManifestPath 'Toolkit/modules/NvrHealth/NvrHealth.psm1')
Check 'paths: NvrHealth folders' (((Get-TkPaths $tkDir).NvrHealth -like '*\modules\NvrHealth') -and ((Get-TkPaths $tkDir).NvrDaily -like '*\NvrHealth'))
$cfgD = Get-TkConfig $tmp
Check 'days: YKW 45 by default' ((Get-TkDaysToKeep $cfgD 'YKW S Elm Street') -eq 45)
Check 'days: other sites 30' ((Get-TkDaysToKeep $cfgD 'Fairbridge Commons') -eq 30 -and (Get-TkDaysToKeep $cfgD '') -eq 30)
Check 'days: not case sensitive, word inside' ((Get-TkDaysToKeep $cfgD 'ykw girls library') -eq 45 -and (Get-TkDaysToKeep $cfgD 'Library YKW') -eq 45 -and (Get-TkDaysToKeep $cfgD 'Bykwood') -eq 30)
$cd = Join-Path $tmp 'cfgdays'; New-Item -ItemType Directory -Force -Path $cd | Out-Null
Set-Content (Join-Path $cd 'config.json') '{"daysToKeep":{"default":21,"sites":{"YKW":45,"Fairbridge":60}}}'
$cfgE = Get-TkConfig $cd
Check 'days: config.json overrides' ((Get-TkDaysToKeep $cfgE 'Fairbridge Commons') -eq 60 -and (Get-TkDaysToKeep $cfgE 'Shteeble') -eq 21 -and (Get-TkDaysToKeep $cfgE 'YKW') -eq 45)
$mc = Read-TkJson (Join-Path $tkDir 'config.json')
# an updated PC may have no config.json (updates never ship it): then the built-in defaults are what counts
if (-not $mc) { Check 'days: no config.json here - built-in defaults YKW 45 / 30' ((Get-TkDaysToKeep (Get-TkConfig $tmp) 'YKW') -eq 45) } else {
Check 'days: master config.json has YKW 45 / 30' ($mc -and [int]$mc.daysToKeep.sites.YKW -eq 45 -and [int]$mc.daysToKeep.default -eq 30) }
$rw = Join-Path $tmp 'refw'; $rtk = Join-Path $rw 'Toolkit'; New-Item -ItemType Directory -Force -Path (Join-Path $rtk 'modules\NvrHealth'), (Join-Path $rw 'NvrHealth') | Out-Null
Set-Content (Join-Path $rtk 'modules\NvrHealth\firmware-latest.json') '{"updated":"2026-11-02T10:00:00","models":{"x":{}}}'
Check 'firmware list: own copy when no daily check' ((Get-TkNvrReference $rtk) -like '*modules\NvrHealth\firmware-latest.json')
Set-Content (Join-Path $rw 'NvrHealth\firmware-latest.json') '{"updated":"2026-12-01T05:30:00","models":{"x":{}}}'
Check 'firmware list: newer monthly refresh wins' ((Get-TkNvrReference $rtk) -like '*\NvrHealth\firmware-latest.json' -and (Get-TkNvrReference $rtk) -notlike '*modules*')
Check 'plain end texts' ((Get-TkNvrPlainEnd 'Clock check' 2) -match 'Nothing was changed' -and (Get-TkNvrPlainEnd 'Clock check' 4) -match 'PROBLEM')
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
$mockPy = Join-Path $tkDir 'modules\NvrHealth\tests\mock_devices.py'
if ($py -and (Test-Path $mockPy) -and (Test-Path $nm)) {
  $mp = 18191; $mbase = 'http://127.0.0.1:' + $mp
  $nvrMock = Start-Process -FilePath $py -ArgumentList @($mockPy, $mp) -PassThru -WindowStyle Hidden
  try {
    for ($i = 0; $i -lt 50; $i++) { try { Invoke-WebRequest ($mbase + '/mockctl/writes') -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 200 } }
    $env:NVRCHECK_TEST_PW = 'NvrPass#2026'
    $runs = Join-Path $tmp 'nvrruns'
    $nc = Join-Path $tkDir 'NvrCheck.ps1'
    function NcRun([string[]]$a) { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc @a -RunsDir $runs -MockUrl $mbase -TestAnswer x -CloseAfter 0 2>&1 | Out-String; return @{ out = $o; code = $LASTEXITCODE } }
    function NcLog([string]$mode) { $d = Get-ChildItem $runs -Directory -Filter ('Nvr' + $mode + '-*') | Sort-Object Name -Descending | Select-Object -First 1; if ($d) { return @(ConvertFrom-TkFixLog (Get-Content (Join-Path $d.FullName 'log.txt'))) }; return @() }
    function MockWrites { return @((Invoke-WebRequest ($mbase + '/mockctl/writes') -UseBasicParsing).Content | ConvertFrom-Json) }
    Invoke-WebRequest ($mbase + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
    $x = NcRun @('-Mode', 'Recording', '-Ip', '10.9.0.30', '-Vendor', 'Hikvision', '-Site', 'YKW Test', '-Days', '45')
    $said = (NcLog 'Recording') -join "`n"
    Check 'button 9: recording check runs, problems found' ($x.code -eq 4 -and $said -match 'only 20 of 45 days' -and $said -match 'Target: 45 days') ($x.out + $said)
    Check 'button 9: drive health shown' ($said -match 'drive 1 failing') $said
    Check 'button 9: read-only' ((MockWrites).Count -eq 0)
    $x = NcRun @('-Mode', 'Clock', '-Ip', '10.9.0.30', '-Vendor', 'Hikvision')
    $said = (NcLog 'Clock') -join "`n"
    Check 'button 10: clock check flags the wrong clock' ($x.code -eq 4 -and $said -match '(?i)clock') ($x.out + $said)
    Check 'button 10: read-only' ((MockWrites).Count -eq 0)
    $x = NcRun @('-Mode', 'Firmware', '-Ip', '10.9.0.30', '-Vendor', 'Hikvision')
    $said = (NcLog 'Firmware') -join "`n"
    Check 'button 12: firmware check runs' ($x.code -in @(0, 4) -and $said -match '(?i)firmware') ($x.out + $said)
    Check 'button 12: read-only (reports only)' ((MockWrites).Count -eq 0)
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode FixClock -Ip 10.9.0.30 -Vendor Hikvision -RunsDir $runs -MockUrl $mbase -TestAnswer 'yes' -CloseAfter 0 2>&1 | Out-String
    $said = (NcLog 'FixClock') -join "`n"
    Check 'button 11: plan shown, lower-case yes = NO change' ((MockWrites).Count -eq 0 -and $said -match 'WHAT-IF' -and $said -match 'Nothing was changed') ($o + $said)
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode FixClock -Ip 10.9.0.30 -Vendor Hikvision -RunsDir $runs -MockUrl $mbase -TestAnswer 'YES' -CloseAfter 0 2>&1 | Out-String
    $said = (NcLog 'FixClock') -join "`n"
    Check 'button 11: typed YES = time settings written' ((MockWrites).Count -gt 0 -and $said -match 'You typed YES' -and $said -match 'saved and read back') ($o + $said)
    Check 'no password in any run log' (-not (Select-String -Path (Join-Path $runs '*\log.txt') -Pattern 'NvrPass#2026' -SimpleMatch -Quiet))
  } finally {
    Remove-Item Env:\NVRCHECK_TEST_PW -ErrorAction SilentlyContinue
    try { if ($nvrMock -and -not $nvrMock.HasExited) { Stop-Process -Id $nvrMock.Id -Force } } catch {}
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*mock_devices.py*18191*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
} else { Check 'python for the mock recorders' $false 'python or mock_devices.py missing' }

# 10 site camera list (Nov 3 2026): Find cameras / install snapshot -> the site page. Mock server only, no device, no real site.
Check 'kind: NVR model' ((Get-TkDeviceKind 'DS-7616NXI-I2/16P/S') -eq 'recorder' -and (Get-TkDeviceKind 'NVR302-16S') -eq 'recorder' -and (Get-TkDeviceKind 'iDS-7208HUHI-M1/S') -eq 'recorder')
Check 'kind: camera model' ((Get-TkDeviceKind 'DS-2CD2143G2-I') -eq 'camera' -and (Get-TkDeviceKind 'IPC2124LB-SF28KM-G') -eq 'camera' -and (Get-TkDeviceKind '') -eq 'other')
$scr = Join-Path $tmp 'scanCR'; New-Item -ItemType Directory -Force -Path (Join-Path $scr 'out') | Out-Null
$fake = [ordered]@{ scannedAt = '2026-11-03T09:00:00'; pc = 'TEST'; devices = @(
  [ordered]@{ Brand = 'Hikvision'; Model = 'DS-7616NXI-I2/16P/S'; Serial = 'DS-7616NXI-I2/16P/S1620230101CCRRJ12345678WCVU'; IP = '192.168.1.20'; MAC = '44-19-B6-00-00-01'; Firmware = 'V4.71.105'; Status = 'Activated'; DefaultLoginWorks = 'no (401)' },
  [ordered]@{ Brand = 'Hikvision'; Model = 'DS-2CD2143G2-I'; Serial = 'DS-2CD2143G2-I20230101AAWRK87654321'; IP = '192.168.1.21'; MAC = '44-19-B6-00-01-01'; Firmware = 'V5.7.15'; password = 'Secret#123' },
  [ordered]@{ Brand = 'Other (ONVIF)'; Model = ''; Serial = ''; IP = ''; MAC = '' }) }
($fake | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $scr 'out\latest.json') -Encoding UTF8
$sd = @(Get-TkScanDevices $scr)
Check 'scan list: 2 devices (empty one dropped)' ($sd.Count -eq 2) ($sd | ConvertTo-Json -Depth 3)
Check 'scan list: NVR + camera, fields' ($sd[0].kind -eq 'recorder' -and $sd[1].kind -eq 'camera' -and $sd[1].mac -eq '44-19-B6-00-01-01' -and $sd[1].firmware -eq 'V5.7.15')
Check 'scan list: never a password or login result' (-not (($sd | ConvertTo-Json -Depth 3) -match 'Secret|password|DefaultLogin|401'))
$snapF = Join-Path $tmp 'FixNVR snapshot test.json'
([ordered]@{ site = 'x'; nvrs = @([ordered]@{ brand = 'Hikvision'; model = 'DS-7616NXI-I2/16P/S'; serial = 'S1'; mac = '44:19:B6:00:00:01'; ip = '192.168.1.20'; firmware = 'V4'; channels = @(@{ channel = 1; ip = '192.168.254.2' }) })
  cameras = @([ordered]@{ channel = '1'; brand = 'Hikvision'; model = 'DS-2CD2143G2-I'; serial = 'C1'; mac = '44:19:B6:00:01:01'; ip = '192.168.1.21' }, [ordered]@{ channel = '2'; model = 'DS-2CD2143G2-I'; serial = 'C2'; mac = 'AA'; ip = '192.168.254.3' }) } | ConvertTo-Json -Depth 6) | Set-Content $snapF -Encoding UTF8
$sn = @(Get-TkSnapshotDevices $snapF)
Check 'snapshot list: NVR + switch camera, not the NVR PoE ports' ($sn.Count -eq 2 -and $sn[0].kind -eq 'recorder' -and $sn[1].channel -eq '1' -and $sn[1].ip -eq '192.168.1.21') ($sn | ConvertTo-Json -Depth 3)
$fa = @(Format-TkScanAnswer ([pscustomobject]@{ ok = $true; site = '2336 Main St'; code = 'WI-064'; same = $true; total = 5; added = @(); changedIp = @(); changed = @(); missing = @(); stillMissing = @(); back = @() }) 'x')
Check 'answer: same scan twice = no changes line' ($fa.Count -eq 1 -and $fa[0].t -match '^No changes .+ site list already up to date \(2336 Main St \(WI-064\), 5 devices\)' -and $fa[0].k -eq 'ok') (($fa | ForEach-Object { $_.t }) -join ' / ')
$fa = @(Format-TkScanAnswer ([pscustomobject]@{ ok = $true; site = 'S'; code = ''; same = $false; total = 6; added = @('Camera X 192.168.1.30'); changedIp = @([pscustomobject]@{ label = 'Camera Y'; from = '192.168.1.22'; to = '192.168.1.42' }); changed = @(); missing = @('Camera Z 192.168.1.23 44:19:B6:00:01:03'); stillMissing = @(); back = @(); alerted = 1 }) 'S')
$red = @($fa | Where-Object { $_.k -eq 'red' } | ForEach-Object { $_.t })
Check 'answer: MISSING / NEW / CHANGED IP in red' ($red.Count -eq 3 -and $red[0] -match '^MISSING since last scan: Camera Z' -and $red[1] -match '^NEW: Camera X' -and $red[2] -match '^CHANGED IP: Camera Y 192.168.1.22 -> 192.168.1.42') ($red -join ' / ')
Check 'answer: alert line' (@($fa | Where-Object { $_.t -match 'Alert sent to the office for 1' }).Count -eq 1)
$fa = @(Format-TkScanAnswer ([pscustomobject]@{ ok = $false; msg = 'Site not found: zz.' }) 'zz'); Check 'answer: refused = plain reason' ($fa[0].t -match 'Not saved to the site page: Site not found')
$fa = @(Format-TkScanAnswer $null 'zz'); Check 'answer: offline = waits for next time' ($fa[0].t -match 'no internet')
$su = Join-Path $tkDir 'ScanUpload.ps1'
$o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -CamResetDir $scr 2>&1 | Out-String
Check 'upload: no site = the tip line' ($o -match 'Tip: type the site to save this list to the site page.') $o
$o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -Site 'WI-064' -CamResetDir $scr -NoSend 2>&1 | Out-String
Check 'upload body: op scanPush, 2 devices, no password' ($o -match '"op":"scanPush"' -and $o -match '"site":"WI-064"' -and ([regex]::Matches($o, '"kind"')).Count -eq 2 -and $o -notmatch 'Secret|password') $o
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
$mockSc = Join-Path $tkDir 'tests\mock_scan_server.py'
if ($py -and (Test-Path $mockSc)) {
  $sp = 18192; $sbase = 'http://127.0.0.1:' + $sp + '/'
  $bodies = Join-Path $tmp 'scan-bodies.txt'
  $scMock = Start-Process -FilePath $py -ArgumentList @($mockSc, $sp, $bodies) -PassThru -WindowStyle Hidden
  try {
    for ($i = 0; $i -lt 50; $i++) { try { Invoke-WebRequest ($sbase + 'ping') -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 200 } }
    $env:WIREIT_UPLOAD_KEY = 'T' * 32
    $lastJ = Join-Path $tkDir 'logs\scan-upload-last.json'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -Site '2336 main' -CamResetDir $scr -ApiUrl ($sbase + 'first') 2>&1 | Out-String
    Check 'upload: first scan saved' ($LASTEXITCODE -eq 0 -and $o -match 'Saved to the site page: 2336 Main St \(WI-064\), 2 devices \(first list') $o
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -Site '2336 main' -CamResetDir $scr -ApiUrl ($sbase + 'same') 2>&1 | Out-String
    Check 'upload: same scan twice = No changes' ($o -match 'No changes .+ site list already up to date') $o
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -Site '2336 main' -CamResetDir $scr -ApiUrl ($sbase + 'missing') 2>&1 | Out-String
    $lj = Read-TkJson $lastJ
    Check 'upload: missing / changed IP marked red for the top of the results' ($o -match '!! MISSING since last scan: Camera DS-2CD2143G2-I 192.168.1.23' -and $o -match '!! CHANGED IP: ' -and $lj -and @($lj.red).Count -eq 2) $o
    $sent = Get-Content $bodies -Raw
    Check 'upload: what reached the server has the key but no password' ($sent -match '"key":"TTTT' -and $sent -notmatch 'Secret|password' -and $sent -match '"pc":') ''
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -Site '2336 main' -CamResetDir $scr -ApiUrl 'http://127.0.0.1:1/' 2>&1 | Out-String
    $pend = Join-Path $tkDir 'outbox\scan-2336_main.json'
    Check 'upload: offline = ONE waiting list, no key in it' ((Test-Path $pend) -and -not ((Get-Content $pend -Raw) -match 'TTTT|"key"') -and $o -match 'no internet') $o
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -Site '2336 main' -CamResetDir $scr -ApiUrl 'http://127.0.0.1:1/' 2>&1 | Out-String
    Check 'upload: offline twice = still ONE waiting list' (@(Get-ChildItem (Join-Path $tkDir 'outbox') -Filter 'scan-*.json').Count -eq 1)
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $su -Site 'WI-070' -CamResetDir $scr -ApiUrl ($sbase + 'first') 2>&1 | Out-String
    Check 'upload: waiting list of the other site goes with the next scan' ($o -match 'Sent the list that was waiting for 2336 main' -and -not (Test-Path $pend)) $o
  } finally {
    Remove-Item Env:\WIREIT_UPLOAD_KEY -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $tkDir 'outbox\scan-*.json') -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $tkDir 'logs\scan-upload-last.json') -Force -ErrorAction SilentlyContinue
    try { if ($scMock -and -not $scMock.HasExited) { Stop-Process -Id $scMock.Id -Force } } catch {}
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*mock_scan_server.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
} else { Check 'python for the mock service site' $false 'python or mock_scan_server.py missing' }

# 11 Check this site (Nov 3 2026): router exposure via UPnP (read-only), summary + fix suggestions, NvrCheck -Mode Site. Mocks only.
Check 'ToolkitCore: UPnP reader refuses a write action' ($(try { Invoke-TkUpnpRead 'http://127.0.0.1:1/' 'urn:x' 'AddPortMapping' | Out-Null; $false } catch { $_.Exception.Message -match 'not a read action' }))
$ux0 = Get-TkUpnpExposure -NoSearch
Check 'router: no answer = green "UPnP off or blocked"' (-not $ux0.answered -and @($ux0.lines | Where-Object { $_.k -eq 'red' }).Count -eq 0 -and $ux0.lines[0].t -match 'did not answer')
if ($py -and (Test-Path $mockSc) -and (Test-Path $mockPy)) {
  $sp = 18193; $sbase = 'http://127.0.0.1:' + $sp + '/'; $bodies2 = Join-Path $tmp 'check-bodies.txt'
  $mp = 18191; $mbase = 'http://127.0.0.1:' + $mp
  $scMock = Start-Process -FilePath $py -ArgumentList @($mockSc, $sp, $bodies2) -PassThru -WindowStyle Hidden
  $nvrMock = Start-Process -FilePath $py -ArgumentList @($mockPy, $mp) -PassThru -WindowStyle Hidden
  try {
    for ($i = 0; $i -lt 50; $i++) { try { Invoke-WebRequest ($sbase + 'ping') -UseBasicParsing -TimeoutSec 2 | Out-Null; Invoke-WebRequest ($mbase + '/mockctl/writes') -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 200 } }
    $ux = Get-TkUpnpExposure -Locations @($sbase + 'igd.xml') -CameraIps @('192.168.1.20')
    $soap = @(Get-Content $bodies2 | Where-Object { $_ -like 'SOAP *' })
    Check 'router: UPnP ON found, model read' ($ux.answered -and $ux.upnp -and $ux.router -eq 'Technicolor CGM4331COM' -and $ux.external -eq '73.1.2.3') ($ux | ConvertTo-Json -Depth 4)
    Check 'router: 3 port maps read, 2 reach a camera/NVR (NVR IP + RTSP port), Xbox not flagged' (@($ux.maps).Count -eq 3 -and @($ux.exposed).Count -eq 2 -and -not (@($ux.exposed).client -contains '192.168.1.50'))
    Check 'router: red lines = UPnP on + one per open camera port' (@($ux.lines | Where-Object { $_.k -eq 'red' }).Count -eq 3 -and (($ux.lines.t -join "`n") -match 'OPEN TO THE INTERNET: port 5554/TCP -> 192.168.1.21:554'))
    Check 'router: only read calls reached the router' ($soap.Count -ge 4 -and -not ($soap | Where-Object { $_ -notmatch '^SOAP (GetGenericPortMappingEntry|GetExternalIPAddress)$' })) ($soap -join ', ')
    # summary from a canned health result
    $h = [pscustomobject]@{ vendor = 'Hikvision'; ok = $false
      recording = [pscustomobject]@{ ok = $false; recording = 2; days_held = 20; target_days = 45; problems = @('camera 3 not recording', 'only 20 of 45 days'); streams = [pscustomobject]@{ checked = 3; flags = @('camera 2 main 30 fps -> 15 is plenty') }
        channels = @([pscustomobject]@{ ch = 1; online = $true; scheduled = $true; recording_now = $true; mode = 'continuous' }, [pscustomobject]@{ ch = 2; online = $true; scheduled = $true; recording_now = $true; mode = 'continuous' }, [pscustomobject]@{ ch = 3; online = $false; scheduled = $false; recording_now = $false; mode = '' }) }
      clock = [pscustomobject]@{ ok = $false; problems = @('clock 9 min off') }; firmware = [pscustomobject]@{ ok = $true; problems = @() } }
    $sc = [pscustomobject]@{ answer = [pscustomobject]@{ ok = $true; total = 3; missing = @('Camera X 192.168.1.23'); stillMissing = @(); added = @(); changedIp = @() } }
    $chk = New-TkSiteCheck -Health $h -Scan $sc -Upnp $ux -Site 'WI-TEST' -Ip '192.168.1.20'
    $red = @($chk.lines | Where-Object { $_.k -eq 'red' })
    Check 'summary: cameras / recording / clock / router red, firmware green' (-not $chk.ok -and $red.Count -eq 6 -and ($chk.lines.t -join "`n") -match 'Firmware: current' -and ($chk.lines.t -join "`n") -match 'Cameras: 1 MISSING of 3') (($chk.lines | ForEach-Object { $_.k + ' ' + $_.t }) -join "`n")
    Check 'summary: fix buttons only for what failed (recording, restart, readd, ntp - not firmware)' ((($chk.fixes | Sort-Object) -join ',') -eq 'ntp,readd,recording,restart') ($chk.fixes -join ',')
    $pj = $chk.page | ConvertTo-Json -Depth 6 -Compress
    Check 'summary: page record small, no password' ($pj.Length -lt 4000 -and $pj -notmatch '(?i)password|NvrPass') $pj
    $hOk = [pscustomobject]@{ vendor = 'Hikvision'; ok = $true; recording = [pscustomobject]@{ ok = $true; recording = 3; days_held = 46; target_days = 45; problems = @(); channels = @() }; clock = [pscustomobject]@{ ok = $true; problems = @() }; firmware = [pscustomobject]@{ ok = $true; problems = @() } }
    $chk2 = New-TkSiteCheck -Health $hOk -Scan $null -Upnp $ux0
    Check 'summary: all fine = ok, no fixes' ($chk2.ok -and -not @($chk2.fixes).Count)
    # NvrCheck -Mode Site end to end (mock recorder + mock site + mock router)
    $env:NVRCHECK_TEST_PW = 'NvrPass#2026'; $env:WIREIT_UPLOAD_KEY = 'T' * 32
    $lastJ = Join-Path $tkDir 'logs\scan-upload-last.json'
    ([ordered]@{ at = (Get-Date -Format 's'); site = 'WI-TEST'; snapshot = $false; sent = $true; answer = $sc.answer; lines = @('Saved to the site page: WI-TEST, 3 devices.', '!! MISSING since last scan: Camera X 192.168.1.23'); red = @('!! MISSING since last scan: Camera X 192.168.1.23') } | ConvertTo-Json -Depth 6) | Set-Content $lastJ -Encoding UTF8
    Invoke-WebRequest ($mbase + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
    $runs = Join-Path $tmp 'nvrruns-site'; $nc = Join-Path $tkDir 'NvrCheck.ps1'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode Site -Ip 10.9.0.30 -Vendor Hikvision -Site 'WI-TEST' -Days 45 -RunsDir $runs -MockUrl $mbase -TestAnswer x -CloseAfter 0 -UpnpLocation ($sbase + 'igd.xml') -ApiUrl ($sbase + 'changed') 2>&1 | Out-String
    $code = $LASTEXITCODE
    $d = Get-ChildItem $runs -Directory -Filter 'NvrSite-*' | Select-Object -First 1
    $said = $(if ($d) { (ConvertFrom-TkFixLog (Get-Content (Join-Path $d.FullName 'log.txt'))) -join "`n" } else { '' })
    Check 'Check this site: 3 steps, summary, problems = code 4' ($code -eq 4 -and $said -match 'Step 1 of 3' -and $said -match 'Step 2 of 3' -and $said -match 'Step 3 of 3' -and $said -match 'CHECK THIS SITE: SUMMARY') ($o + $said)
    Check 'Check this site: router red lines and the missing camera in the summary' ($said -match 'Router UPnP is ON' -and $said -match 'OPEN TO THE INTERNET' -and $said -match 'Cameras: 1 MISSING') $said
    Check 'Check this site: saved as Latest check, change noted' ($said -match 'Saved as the "Latest check" on the site page: WI-TEST \(something changed') $said
    $sent = @(Get-Content $bodies2 | Where-Object { $_ -like '{*' } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.op -eq 'toolkitCheck' })
    Check 'Check this site: ONE toolkitCheck sent, with key + check, no password' ($sent.Count -eq 1 -and $sent[0].site -eq 'WI-TEST' -and $sent[0].check.rec -and ((Get-Content $bodies2 -Raw) -notmatch 'NvrPass')) ''
    Check 'Check this site: read-only (no write reached the recorder)' (((Invoke-WebRequest ($mbase + '/mockctl/writes') -UseBasicParsing).Content).Trim() -eq '[]')
    Check 'Check this site: result kept for the Toolkit window' (Test-Path (Join-Path $tkDir 'logs\check-site-last.json'))
    Check 'Check this site: no password in the run log' (-not (Select-String -Path (Join-Path $runs '*\*') -Pattern 'NvrPass#2026' -SimpleMatch -Quiet))
    # DW site (like YKW Elm): offline list with last recording + likely cause, days from the DW server's name, curl fallback
    $env:WIREIT_TEST_REACH = '{"10.9.1.29":{"ping":true,"mac":"44:19:B6:00:0A:29","ports":[80,554]},"10.9.1.30":{"ping":false,"mac":"","ports":[]},"10.9.1.11":{"ping":true,"mac":"44:19:B6:00:0A:11","ports":[80,554]}}'
    Invoke-WebRequest ($mbase + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
    Remove-Item (Join-Path $tkDir 'logs\scan-upload-last.json') -Force -ErrorAction SilentlyContinue
    $runs2 = Join-Path $tmp 'nvrruns-dw'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode Site -Ip 10.9.0.41 -Days 0 -RunsDir $runs2 -MockUrl $mbase -TestAnswer x -CloseAfter 0 -NoUpnp -NoSend 2>&1 | Out-String
    $d = Get-ChildItem $runs2 -Directory -Filter 'NvrSite-*' | Select-Object -First 1
    $said = $(if ($d) { (ConvertFrom-TkFixLog (Get-Content (Join-Path $d.FullName 'log.txt'))) -join "`n" } else { '' })
    Check 'DW site: days to keep from the DW server name (YKW -> 45)' ($said -match 'Days to keep: 45 \(from the DW server name "YKW-TEST"\)') ($o + $said)
    Check 'DW site: Offline in DW lists the 2 problem cameras, not the good one' ($said -match 'Offline in DW' -and $said -match 'Dining Room Center \(10\.9\.1\.29\) - DW: Unauthorized, last recording .+ \(54 days ago\): DW HAS THE WRONG PASSWORD' -and $said -match 'Back Stairs \(10\.9\.1\.30\) - DW: Offline, .+NO LINK' -and $said -notmatch 'Lobby \(10\.9\.1\.11\) - DW') $said
    $cj = Read-TkJson (Join-Path $tkDir 'logs\check-site-last.json')
    Check 'DW site: summary carries the DW list + fix dwpassword' ($cj -and [int]$cj.page.dw.problems -eq 2 -and (@($cj.fixes) -contains 'dwpassword')) ($cj | ConvertTo-Json -Depth 6)
    Check 'DW site: read-only' ((((Invoke-WebRequest ($mbase + '/mockctl/writes') -UseBasicParsing).Content).Trim()) -eq '[]')
    Check '1.6.3 DW site: no "Put the camera back on the NVR", no "Restart" for a camera with no link (dead + wrong DW password only)' ($cj -and -not (@($cj.fixes) -contains 'readd') -and -not (@($cj.fixes) -contains 'restart')) (@($cj.fixes) -join ',')
    Check '1.6.3 DW site: Recording line names the cameras (name + IP), no DW list numbers' ($said -match 'Recording: 2 camera\(s\) not recording: Dining Room Center \(10\.9\.1\.29\), Back Stairs \(10\.9\.1\.30\)' -and $said -notmatch 'not recording: \d') $said
    $lo = [int](((Invoke-WebRequest ($mbase + '/mockctl/logouts/10.9.0.41') -UseBasicParsing).Content | ConvertFrom-Json).logouts)
    Check '1.6.3 DW site: logged out of DW at the end (one DELETE), one login' ($lo -eq 1 -and $said -match 'Logged out of the DW server' -and [int](((Invoke-WebRequest ($mbase + '/mockctl/tries/10.9.0.41') -UseBasicParsing).Content | ConvertFrom-Json).tries) -eq 1) ('logouts=' + $lo)
    # 1.6.1 (YKW Elm live test Nov 3 2026): failed / skipped DW login, unreadable clock, fresh local camera list, no DW firmware fix
    $crf = Join-Path $tmp 'cr-fresh'; $sdir = Join-Path $crf 'out\scan-20261103-035654'; New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    '[{"Brand":"Uniview","Model":"IPC3612LB","IP":"10.9.1.11","MAC":"44:19:B6:00:0A:11","Serial":"S1"},{"Brand":"Unknown","Model":"","IP":"10.9.1.99","MAC":"44:19:B6:00:0A:99","Kind":"camera","SweepOnly":true},{"Brand":"Hikvision","Model":"DS-7608NI-K2","IP":"10.9.0.30","MAC":"44:19:B6:00:00:30"}]' | Set-Content (Join-Path $sdir 'devices.json') -Encoding UTF8
    $fs = Get-TkFreshScan $crf 30
    Check '1.6.1 fresh camera list read from this PC (no upload): 3 devices, 2 cameras' ($fs -and $fs.local -and $fs.count -eq 3 -and $fs.cameras -eq 2) ($fs | ConvertTo-Json -Depth 3)
    (Get-Item (Join-Path $sdir 'devices.json')).LastWriteTime = (Get-Date).AddHours(-2)
    Check '1.6.1 a camera list older than 30 min is not used' ($null -eq (Get-TkFreshScan $crf 30))
    (Get-Item (Join-Path $sdir 'devices.json')).LastWriteTime = (Get-Date)
    $env:NVRCHECK_TEST_PW = 'WrongPw#1'
    Invoke-WebRequest ($mbase + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
    Remove-Item (Join-Path $tkDir 'logs\scan-upload-last.json'), (Join-Path $tkDir 'logs\check-site-last.json') -Force -ErrorAction SilentlyContinue
    $runs4 = Join-Path $tmp 'nvrruns-dwref'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode Site -Ip 10.9.0.41 -Days 0 -Cameras -RunsDir $runs4 -MockUrl $mbase -TestAnswer x -CloseAfter 0 -NoUpnp -NoSend -CamResetDir $crf 2>&1 | Out-String
    $d = Get-ChildItem $runs4 -Directory -Filter 'NvrSite-*' | Select-Object -First 1
    $said = $(if ($d) { (ConvertFrom-TkFixLog (Get-Content (Join-Path $d.FullName 'log.txt'))) -join "`n" } else { '' })
    $cj = Read-TkJson (Join-Path $tkDir 'logs\check-site-last.json')
    $tries = [int](((Invoke-WebRequest ($mbase + '/mockctl/tries/10.9.0.41') -UseBasicParsing).Content | ConvertFrom-Json).tries)
    $cl = @($(if ($cj) { $cj.lines } else { @() }))
    Check '1.6.1 DW login refused: "Offline in DW: NOT CHECKED (login refused)" in amber' ($said -match 'Offline in DW: NOT CHECKED \(login refused\)' -and @($cl | Where-Object { $_.t -eq 'Offline in DW: NOT CHECKED (login refused)' -and $_.k -eq 'warn' }).Count -eq 1) ($o + $said)
    Check '1.6.1 DW login refused: never "every camera online" / "0 camera(s)" / all OK' ($said -notmatch '(?i)every camera' -and $said -notmatch 'none - all' -and $said -notmatch '0 camera\(s\)' -and $cj -and -not $cj.ok -and -not @($cl | Where-Object { $_.k -eq 'ok' -and $_.t -match 'DW' }).Count) $said
    Check '1.6.1 DW login refused: ONE login try for the whole check' ($tries -eq 1) ('tries=' + $tries)
    Check '1.6.1 unreadable clock = "Clock: not checked", no "time needs fixing", no time fix offered' ($said -match 'Clock: not checked' -and $said -notmatch 'time needs fixing' -and -not (@($cj.fixes) -contains 'ntp')) ($said + ' fixes=' + (@($cj.fixes) -join ','))
    Check '1.6.1 recording NOT CHECKED + "not an all-clear" in the summary' ($said -match 'Recording: NOT CHECKED \(login refused\)' -and $said -match 'this is not an all-clear') $said
    Check '1.6.1 DW server: firmware report only, no "Update firmware" fix' (-not (@($cj.fixes) -contains 'firmware') -and $said -match 'Firmware \(report only') ($said + ' fixes=' + (@($cj.fixes) -join ','))
    Check '1.6.1 Check this site uses the fresh local Find-cameras list (no Site ID, no upload)' ($said -notmatch 'No fresh camera list' -and $said -match 'Find cameras found 3 device' -and $said -match 'Cameras: 3 found on the network by Find cameras just now') $said
    Remove-Item Env:\NVRCHECK_TEST_PW -ErrorAction SilentlyContinue
    Invoke-WebRequest ($mbase + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
    $runs5 = Join-Path $tmp 'nvrruns-dwskip'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode Site -Ip 10.9.0.41 -Days 0 -Cameras -RunsDir $runs5 -MockUrl $mbase -TestAnswer x -CloseAfter 0 -NoUpnp -NoSend -CamResetDir (Join-Path $tmp 'cr-none') 2>&1 | Out-String
    $d = Get-ChildItem $runs5 -Directory -Filter 'NvrSite-*' | Select-Object -First 1
    $said = $(if ($d) { (ConvertFrom-TkFixLog (Get-Content (Join-Path $d.FullName 'log.txt'))) -join "`n" } else { '' })
    $tries = [int](((Invoke-WebRequest ($mbase + '/mockctl/tries/10.9.0.41') -UseBasicParsing).Content | ConvertFrom-Json).tries)
    Check '1.6.1 empty recorder password = login skipped: NO login sent, NOT CHECKED (login skipped)' ($tries -eq 0 -and $said -match 'Recorder login skipped' -and $said -match 'Offline in DW: NOT CHECKED \(login skipped\)' -and $said -notmatch '(?i)every camera') ('tries=' + $tries + "`n" + $o + $said)
    $env:NVRCHECK_TEST_PW = 'NvrPass#2026'
    # 1.6.3 (YKW Elm 1.6.2 live run): camera clocks from the Find list without a login, logout even after an error
    $cr3 = Join-Path $tmp 'cr-163'; $sd3 = Join-Path $cr3 ('out\scan-' + (Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item -ItemType Directory -Force -Path $sd3 | Out-Null
    '[{"Brand":"Uniview","Model":"IPC2124LB","IP":"10.9.1.21","MAC":"44:19:B6:00:0A:21"},{"Brand":"Uniview","Model":"IPC2124LB","IP":"10.9.1.22","MAC":"44:19:B6:00:0A:22"},{"Brand":"Uniview","Model":"IPC2124LB","IP":"10.9.1.23","MAC":"44:19:B6:00:0A:23"},{"Brand":"DW","Model":"DW Spectrum","IP":"10.9.0.41","MAC":"44:19:B6:00:00:41","Kind":"recorder"}]' | Set-Content (Join-Path $sd3 'devices.json') -Encoding UTF8
    Invoke-WebRequest ($mbase + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
    Remove-Item (Join-Path $tkDir 'logs\scan-upload-last.json'), (Join-Path $tkDir 'logs\check-site-last.json') -Force -ErrorAction SilentlyContinue
    $runs6 = Join-Path $tmp 'nvrruns-163'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode Site -Ip 10.9.0.41 -Days 0 -Cameras -RunsDir $runs6 -MockUrl $mbase -TestAnswer x -CloseAfter 0 -NoUpnp -NoSend -CamResetDir $cr3 2>&1 | Out-String
    $d = Get-ChildItem $runs6 -Directory -Filter 'NvrSite-*' | Select-Object -First 1
    $said = $(if ($d) { (ConvertFrom-TkFixLog (Get-Content (Join-Path $d.FullName 'log.txt'))) -join "`n" } else { '' })
    $cj = Read-TkJson (Join-Path $tkDir 'logs\check-site-last.json')
    $au = { param($ip) [int](((Invoke-WebRequest ($mbase + '/mockctl/auth/' + $ip) -UseBasicParsing).Content | ConvertFrom-Json).auth) }
    Check '1.6.3 clocks: the Find-cameras list is used (3 cameras), no "No cameras reachable"' ($said -notmatch 'No cameras reachable' -and $said -match 'Camera clocks: 3 camera\(s\) from the Find cameras list, read WITHOUT a login') ($o + $said)
    Check '1.6.3 clocks: wrong camera clock reported, right one summed up, silent one not checked' ($said -match 'Camera 10\.9\.1\.22: clock is 10 minutes ahead' -and $said -match '1 camera clock\(s\) correct' -and $said -match 'did not answer the no-login time read - not checked: 10\.9\.1\.23') $said
    Check '1.6.3 clocks: no password sent to any camera, no "Fix time" button for a DW camera clock' ((& $au '10.9.1.21') -eq 0 -and (& $au '10.9.1.22') -eq 0 -and $cj -and -not (@($cj.fixes) -contains 'ntp')) ('fixes=' + (@($cj.fixes) -join ','))
    Check '1.6.3 firmware: no flood of "not in the reference list" lines' (@(($said -split "`n") | Where-Object { $_ -match 'not in the reference list' }).Count -le 1) $said
    Check '1.6.3 run: logged out of DW at the end, still read-only' ([int](((Invoke-WebRequest ($mbase + '/mockctl/logouts/10.9.0.41') -UseBasicParsing).Content | ConvertFrom-Json).logouts) -eq 1 -and (((Invoke-WebRequest ($mbase + '/mockctl/writes') -UseBasicParsing).Content).Trim()) -eq '[]')
    Invoke-WebRequest ($mbase + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
    $env:NVRCHECK_TEST_THROW = 'test: the check stopped after the DW login'
    $runs7 = Join-Path $tmp 'nvrruns-163err'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode Site -Ip 10.9.0.41 -Days 0 -RunsDir $runs7 -MockUrl $mbase -TestAnswer x -CloseAfter 0 -NoUpnp -NoSend -CamResetDir (Join-Path $tmp 'cr-none') 2>&1 | Out-String
    Remove-Item Env:\NVRCHECK_TEST_THROW -ErrorAction SilentlyContinue
    $d = Get-ChildItem $runs7 -Directory -Filter 'NvrSite-*' | Select-Object -First 1
    $said = $(if ($d) { (ConvertFrom-TkFixLog (Get-Content (Join-Path $d.FullName 'log.txt'))) -join "`n" } else { '' })
    $lo = [int](((Invoke-WebRequest ($mbase + '/mockctl/logouts/10.9.0.41') -UseBasicParsing).Content | ConvertFrom-Json).logouts)
    Check '1.6.3 a check that stops with an error still logs out of DW (finally)' ($lo -eq 1 -and $said -match 'PROBLEM test: the check stopped after the DW login' -and $said -match 'Logged out of the DW server') ('logouts=' + $lo + "`n" + $o + $said)
    Check '1.6.3 no session token in any run log' (-not (Select-String -Path (Join-Path $tmp 'nvrruns-163*\*\*') -Pattern 'vms-TESTTOKEN' -SimpleMatch -Quiet))
    # 1.6.3 fix buttons: no "Restart" for a camera with no network link, no "Put back on the NVR" on a DW server
    $hDw = [pscustomobject]@{ vendor = 'DW'; ok = $false; recording = [pscustomobject]@{ ok = $false; recording = 1; days_held = 50; target_days = 45; problems = @('1 camera(s) not recording: Gone (10.9.9.1)'); channels = @([pscustomobject]@{ ch = 1; ip = '10.9.9.1'; online = $false; scheduled = $true; recording_now = $false; mode = '' }) }; clock = [pscustomobject]@{ ok = $true; problems = @() }; firmware = [pscustomobject]@{ ok = $true; problems = @() } }
    $dDead = @([pscustomobject]@{ name = 'Gone'; ip = '10.9.9.1'; status = 'Offline'; hours = 900; cause = 'dead'; t = 'Gone (10.9.9.1) - NO LINK' })
    $c1 = New-TkSiteCheck -Health $hDw -Scan $null -Upnp $null -Ip '10.9.0.41' -Dw $dDead
    Check '1.6.3 DW, camera with NO LINK: no Restart, no Put-back-on-NVR' (-not (@($c1.fixes) -contains 'restart') -and -not (@($c1.fixes) -contains 'readd')) (@($c1.fixes) -join ',')
    $dHung = @([pscustomobject]@{ name = 'Stuck'; ip = '10.9.9.2'; status = 'Offline'; hours = 30; cause = 'hung'; t = 'Stuck (10.9.9.2) - HUNG' })
    $c2 = New-TkSiteCheck -Health $hDw -Scan $null -Upnp $null -Ip '10.9.0.41' -Dw $dHung
    Check '1.6.3 DW, camera still on the network (hung): Restart offered, never Put-back-on-NVR' ((@($c2.fixes) -contains 'restart') -and -not (@($c2.fixes) -contains 'readd')) (@($c2.fixes) -join ',')
    $prevReach = $env:WIREIT_TEST_REACH
    $env:WIREIT_TEST_REACH = '{"192.168.1.33":{"ping":false,"mac":"","ports":[]},"192.168.1.34":{"ping":true,"mac":"44:19:B6:00:01:34","ports":[80]}}'
    $hNvr = { param($ip) [pscustomobject]@{ vendor = 'Hikvision'; ok = $false; recording = [pscustomobject]@{ ok = $false; recording = 1; days_held = 50; target_days = 45; problems = @('1 camera(s) not recording: 3'); channels = @([pscustomobject]@{ ch = 3; ip = $ip; online = $false; scheduled = $true; recording_now = $false; mode = '' }) }; clock = [pscustomobject]@{ ok = $true; problems = @() }; firmware = [pscustomobject]@{ ok = $true; problems = @() } } }
    $c3 = New-TkSiteCheck -Health (& $hNvr '192.168.1.33') -Scan $null -Upnp $null -Ip '192.168.1.20'
    $c4 = New-TkSiteCheck -Health (& $hNvr '192.168.1.34') -Scan $null -Upnp $null -Ip '192.168.1.20'
    Check '1.6.3 NVR, offline camera with no link: no Restart (Put back on the NVR stays)' (-not (@($c3.fixes) -contains 'restart') -and (@($c3.fixes) -contains 'readd')) (@($c3.fixes) -join ',')
    Check '1.6.3 NVR, offline camera that still pings: Restart offered' ((@($c4.fixes) -contains 'restart') -and (@($c4.fixes) -contains 'readd')) (@($c4.fixes) -join ',')
    $scM = [pscustomobject]@{ answer = [pscustomobject]@{ ok = $true; total = 3; missing = @('Camera X 192.168.1.23'); stillMissing = @(); added = @(); changedIp = @() } }
    $hOk2 = [pscustomobject]@{ vendor = 'Hikvision'; ok = $true; recording = [pscustomobject]@{ ok = $true; recording = 3; days_held = 46; target_days = 45; problems = @(); channels = @() }; clock = [pscustomobject]@{ ok = $true; problems = @() }; firmware = [pscustomobject]@{ ok = $true; problems = @() } }
    $c5 = New-TkSiteCheck -Health $hOk2 -Scan $scM -Upnp $null -Site 'WI-TEST' -Ip '192.168.1.20'
    Check '1.6.3 a camera MISSING from Find cameras (no link): no Restart button' (-not (@($c5.fixes) -contains 'restart')) (@($c5.fixes) -join ',')
    $env:WIREIT_TEST_REACH = $prevReach
    # summary unit checks (canned results)
    $dwRef = [pscustomobject]@{ vendor = 'DW'; ok = $false; recording = [pscustomobject]@{ ok = $false; vendor = 'DW'; recording = 0; channels = @(); problems = @('login refused') }; clock = [pscustomobject]@{ ok = $false; problems = @('clock not checked') }; firmware = [pscustomobject]@{ ok = $false; problems = @('Server: CVE-2026-78414') } }
    $k1 = New-TkSiteCheck -Health $dwRef -Scan $null -Upnp $null -Dw @()
    Check '1.6.1 summary: empty DW list after a refused login is NOT CHECKED, never green (old bug input)' (-not $k1.ok -and (($k1.lines.t) -contains 'Offline in DW: NOT CHECKED (login refused)') -and -not (($k1.lines.t -join "`n") -match '(?i)every camera|none - all') -and -not (@($k1.fixes) -contains 'ntp') -and -not (@($k1.fixes) -contains 'firmware')) (($k1.lines | ForEach-Object { $_.k + ' ' + $_.t }) -join "`n")
    $hikFw = [pscustomobject]@{ vendor = 'Hikvision'; ok = $false; recording = [pscustomobject]@{ ok = $true; recording = 2; days_held = 46; target_days = 45; problems = @(); channels = @() }; clock = [pscustomobject]@{ ok = $false; problems = @('camera 10.9.0.21: clock not checked') }; firmware = [pscustomobject]@{ ok = $false; problems = @('Recorder: CVE-2021-36260') } }
    $tl = Join-Path $tmp 'tail-test.txt'; Set-Content $tl 'start'
    $rd = New-Object IO.FileStream($tl, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    $okW = 0; for ($q = 0; $q -lt 200; $q++) { if (Add-TkLine $tl ('line ' + $q)) { $okW++ } }; $rd.Dispose()
    Check '1.6.2 run log: 200 lines written while the window is reading the file' ($okW -eq 200 -and (Get-Content $tl).Count -eq 201) ('written=' + $okW)
    $k3 = New-TkSiteCheck -Health $null -Scan $null -Upnp $null -StopWhy "The process cannot access the file 'log.txt' because it is being used by another process."
    Check '1.6.2 summary: a check that stopped says so (not "no login"), NOT CHECKED, never green' (-not $k3.ok -and (($k3.lines.t -join "`n") -match 'check stopped with a problem') -and -not (($k3.lines.t -join "`n") -match 'no answer or no login') -and (@($k3.page.notChecked) -contains 'recorder')) (($k3.lines | ForEach-Object { $_.k + ' ' + $_.t }) -join "`n")
    $k2 = New-TkSiteCheck -Health $hikFw -Scan $null -Upnp $null
    Check '1.6.1 summary: Hikvision firmware hole still offers the firmware fix; clock not checked offers no time fix' ((@($k2.fixes) -contains 'firmware') -and -not (@($k2.fixes) -contains 'ntp') -and (($k2.lines.t) -match '^Clock: not checked')) (($k2.lines | ForEach-Object { $_.k + ' ' + $_.t }) -join "`n")
    Check 'vendor box: dw / DW Spectrum / hik / blank' ((Get-TkVendorArg 'DW Spectrum') -eq 'DW' -and (Get-TkVendorArg 'dw') -eq 'DW' -and (Get-TkVendorArg 'hikvision') -eq 'Hikvision' -and (Get-TkVendorArg '') -eq 'Auto')
    # Camera doctor (ONE login try max)
    $runs3 = Join-Path $tmp 'nvrruns-doc'
    function DocRun([string[]]$a) { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nc -Mode Doctor @a -RunsDir $runs3 -MockUrl $mbase -TestAnswer x -CloseAfter 0 2>&1 | Out-String; $j = Read-TkJson (Join-Path $tkDir 'logs\doctor-last.json'); return @{ out = $o; j = $j; code = $LASTEXITCODE } }
    $x = DocRun @('-Ip', '10.9.1.29', '-DwIp', '10.9.0.41')
    $tries = ((Invoke-WebRequest ($mbase + '/mockctl/tries/10.9.1.29') -UseBasicParsing).Content | ConvertFrom-Json).tries
    Check 'doctor: locked Uniview + DW Unauthorized -> LOCKED, DW keeps retrying, fix dwpassword' ($x.j -and $x.j.login -eq 'locked' -and $x.j.lockMin -eq 29 -and $x.j.dw -eq 'Unauthorized' -and $x.j.verdict -match 'DW keeps retrying the old password' -and (@($x.j.fixes) -contains 'dwpassword') -and $x.code -eq 4) ($x.out + ($x.j | ConvertTo-Json -Depth 4))
    Check 'doctor: never more than ONE login try (probe + 1 try + page)' ($tries -le 3) ('tries=' + $tries)
    $env:WIREIT_TEST_REACH = '{"10.9.1.31":{"ping":true,"mac":"44:19:B6:00:0A:31","ports":[80,554],"rtsp":"hung"},"10.9.1.32":{"ping":false,"mac":"","ports":[]},"10.9.0.50":{"ping":true,"mac":"44:19:B6:00:00:50","ports":[80,554],"rtsp":"answers 401"}}'
    $x = DocRun @('-Ip', '10.9.1.31')
    Check 'doctor: hung web service -> HUNG, restart PoE' ($x.j -and $x.j.web -eq 'hung' -and $x.j.verdict -match '^HUNG' -and (@($x.j.fixes) -contains 'poe')) ($x.out)
    $x = DocRun @('-Ip', '10.9.1.32')
    Check 'doctor: nothing at the IP -> DEAD / no link, replace' ($x.j -and $x.j.verdict -match '^DEAD' -and (@($x.j.fixes) -contains 'replace')) ($x.out)
    $x = DocRun @('-Ip', '10.9.0.50', '-Maker', 'Uniview')
    Check 'doctor: good Uniview, right password -> fine, no fix' ($x.j -and $x.j.login -eq 'ok' -and $x.j.verdict -match '^The camera itself is fine' -and -not @($x.j.fixes).Count) ($x.out)
    Check 'doctor: no password in its log' (-not (Select-String -Path (Join-Path $runs3 '*\*') -Pattern 'NvrPass#2026' -SimpleMatch -Quiet))
    Remove-Item Env:\WIREIT_TEST_REACH -ErrorAction SilentlyContinue
  } finally {
    Remove-Item Env:\NVRCHECK_TEST_PW, Env:\WIREIT_UPLOAD_KEY, Env:\WIREIT_TEST_REACH -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $tkDir 'logs\scan-upload-last.json'), (Join-Path $tkDir 'logs\check-site-last.json'), (Join-Path $tkDir 'logs\doctor-last.json') -Force -ErrorAction SilentlyContinue
    foreach ($pp in @($scMock, $nvrMock)) { try { if ($pp -and -not $pp.HasExited) { Stop-Process -Id $pp.Id -Force } } catch {} }
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*mock_scan_server.py*' -or $_.CommandLine -like '*mock_devices.py*18191*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
} else { Check 'python for the Check this site mocks' $false 'python or mocks missing' }
$ui0 = Get-Content (Join-Path $tkDir 'WireItToolkit.ps1') -Raw
Check 'UI: Check this site button, read-only chain Find -> upload -> NvrCheck Site' ($ui0 -match "New-Btn 'Check this site \(read-only\)' \{ Do-SiteCheck \}" -and $ui0 -match "Start-Nvr 'Check this site' 'Site'" -and $ui0 -match 'Invoke-AfterScan')
$ui = Get-Content (Join-Path $tkDir 'WireItToolkit.ps1') -Raw
Check 'Find cameras: uploads when the Site box is filled, else the tip' ($ui -match "Start-ScanUpload ''\s*\}" -and $ui -match 'Tip: type the site to save this list to the site page\.')
Check 'Save camera pictures: one-field dialog passes ONE field' ($ui -match "\(,@\('site', 'Site ID or address:'")
Check '1.6.1 UI: "not checked" results are amber, never "all OK"' ($ui -match 'NOT everything could be checked \(this is not an all-clear\)' -and $ui -match "Leave the password empty to skip the login")
Check 'install snapshot: also the site known-good list' ($ui -match 'Start-ScanUpload \$sn\.FullName')

# 8 the window itself, drawn off-screen to PNG (no window on the desktop)
if ($Screens) {
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $tkDir 'WireItToolkit.ps1') -Screenshot $Screens -DemoCamReset $cr 2>&1 | Out-String
  Check ('window builds (' + $nb + ' buttons)') ($o -match ('buttons=' + $nb + ';')) $o
  Check 'label: Site ID or address' ($o -match '(?m)^label site=Site ID or address:\s*$') $o
  Check 'label: site hint' ($o -match '(?m)^label hint=e\.g\. WI-061 or 2336 Main St\. Saves the camera list and results to that site.s page\.\s*$') $o
  Check 'label: lone cameras in plain words' ($o -match '(?m)^label lone=Also fix cameras plugged into the switch that aren.t added to the NVR\s*$') $o
  Check 'Bitwarden only under Advanced (no password radio buttons)' ($o -match '(?m)^main radios=0' -and $o -match 'label advanced=Advanced\.\.\. items=Read NVR passwords from a Bitwarden export file\.\.\.') $o
  Check '1-field dialog = exactly 1 labelled box' ($o -match '(?m)^ask1 boxes=1 labels=Site ID or address: value=WI-061') $o
  Check 'dialog screenshot saved' (Test-Path (Join-Path $Screens 'toolkit-ask-site.png')) $o
  Check 'screenshots saved' ((Test-Path (Join-Path $Screens 'toolkit-main.png')) -and (Test-Path (Join-Path $Screens 'toolkit-reset.png'))) $o
  Check 'new look built (rounded cards, header)' ($o -match 'look=new') $o
  Check 'icon font found' ($o -match 'icons=Segoe') $o
  $s150 = Join-Path $Screens 'at150'
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $tkDir 'WireItToolkit.ps1') -Screenshot $s150 -SimScale 1.5 -DemoCamReset $cr 2>&1 | Out-String
  Check 'window builds at 150% (the Dell screen)' (($o -match ('buttons=' + $nb + ';')) -and ($o -match 'scale=1.5') -and (Test-Path (Join-Path $s150 'toolkit-main.png'))) $o
  $s1024 = Join-Path $Screens 'at1024'
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $tkDir 'WireItToolkit.ps1') -Screenshot $s1024 -SimScreen 1024x768 -DemoCamReset $cr 2>&1 | Out-String
  Check 'window at 1024x768 (YKW Elm server): builds, picture saved' (($o -match ('buttons=' + $nb + ';')) -and (Test-Path (Join-Path $s1024 'toolkit-small.png'))) $o
  Check '1.6.1 window at 1024x768: no button caption cut off' ($o -match '(?m)^clipped=0\s*$') $o
  $s800 = Join-Path $Screens 'at800'
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $tkDir 'WireItToolkit.ps1') -Screenshot $s800 -SimScreen 800x600 -DemoCamReset $cr 2>&1 | Out-String
  Check 'window at 800x600: scrolls instead of cutting off' ($o -match 'scroll=yes') $o
}
Check 'logo file present' (Test-Path (Join-Path $tkDir 'wireit-logo.png'))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('RESULT ' + $script:pass + ' passed, ' + $script:fail + ' failed')
if ($script:fail) { exit 1 }
