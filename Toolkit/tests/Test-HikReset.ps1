<#
 Test-HikReset.ps1 - WireIt Toolkit 2.2 tests for the Hikvision official-reset flow (pwsh 7 or Windows PowerShell 5.1; needs python3 for the fake devices and the mock reply relay).
   1. SADP: discovery on several subnets, the request file is built exactly like SADP's own, the import tries only a few forms
   2. flow: state file, no second export, expiry, restart check, reply matching, import + login check
   3. mail: saved .eml mails (MIME attachments, codes), matching by serial / short serial / MAC, wrong files never used
   3b. 2.2.0 reply relay (mock HTTPS relay on 127.0.0.1, op hikReplyGet), config fallbacks, the "I got Hik's email" drops
   4. portal: the form is filled and the request file attached on a local copy of Hikvision's page (needs Chrome/Chromium; skipped when absent)
   5. no password and no unlock code in any log line
 Usage: powershell -ExecutionPolicy Bypass -File Test-HikReset.ps1        (exit code = number of failed checks)
#>
param([switch]$NoPortal)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $fx = Join-Path $here 'hikreset'
. (Join-Path $tk 'HikResetFlow.ps1'); . (Join-Path $tk 'HikEmailDrop.ps1')
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
. (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython   # 2.2.5: a real Python, never the Windows Store stub
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('hiktest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
function New-Code([int]$seed) { $b = New-Object byte[] 132; $b[0] = 3; $r = New-Object Random($seed); $x = New-Object byte[] 128; $r.NextBytes($x); [Array]::Copy($x, 0, $b, 4, 128); return [Convert]::ToBase64String($b) }
$PW = 'Wireit4821'
$logLines = New-Object System.Collections.ArrayList
$script:SadpLog = { param($l) [void]$logLines.Add($l) }
$script:HkSay = { param($t, $c) [void]$logLines.Add($t) }

function Start-Py([string[]]$a) { $script:lastPyErr = (Join-Path $tmp ('py' + (Get-Random) + '.err')); $sp = @{ FilePath = $py; ArgumentList = $a; PassThru = $true; RedirectStandardError = $script:lastPyErr }; if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) { $sp.WindowStyle = 'Hidden' }; return (Start-Process @sp) }
function Start-Fake([object[]]$devs, [int]$port) {
  $f = Join-Path $tmp ('devs' + $port + '.json'); ($devs | ConvertTo-Json -Depth 5) | Set-Content $f -Encoding UTF8
  $p = Start-Py @((Join-Path $fx 'fake_sadp.py'), $port, $f)
  $end = (Get-Date).AddSeconds(10); while (-not (Test-Path ($f + '.ready')) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
  $ok = Test-Path ($f + '.ready')
  if (-not $ok) { $er = ''; try { $er = (Get-Content -Raw $script:lastPyErr -ErrorAction SilentlyContinue) } catch {}; Write-Host ('  the fake devices did not start (' + $py + '): ' + $er) -ForegroundColor Red }
  return [pscustomobject]@{ proc = $p; file = $f; port = $port; started = $ok }
}
function Stop-Fake($fk) { Set-Content ($fk.file + '.stop') '1'; Start-Sleep -Milliseconds 800; try { if (-not $fk.proc.HasExited) { $fk.proc.Kill() } } catch {} }
function Fake-State($fk) { Get-Content ($fk.file + '.state.json') -Raw | ConvertFrom-Json }
function Dev([string]$mac, [string]$ip, [string]$sn, [string]$model, [bool]$act, [string]$kind, [int]$seed, [string]$boot = '2026-11-05 19:09:38', [string[]]$ct = @('getcode'), [string[]]$it = @('resetPassword')) {
  @{ mac = $mac; ip = $ip; mask = '255.255.255.0'; gw = ($ip -replace '\.\d+$', '.1'); serial = $sn; model = $model; activated = $act; kind = $kind; boot = $boot; code = (New-Code $seed); unlock = (New-Code ($seed + 500)); codeTypes = $ct; importTypes = $it; password = '' }
}
$SN_NVR = 'ERI-K108-P80820220906CCRRK53440227WCVU'; $SN_C1 = 'ECI-T44F220220815AAWRK43962989'; $SN_C2 = 'ECI-T44F220220903AAWRK52336457'; $SN_C3 = 'ECI-T44F220220903AAWRK52336660'
$devs = @(
  (Dev 'c0-6d-ed-2b-f3-85' '192.168.1.23' $SN_NVR 'ERI-K108-P8' $true 'nvr' 1),
  (Dev 'c0-6d-ed-a7-35-7c' '10.243.1.6' $SN_C1 'ECI-T44F2' $true 'camera' 2),
  (Dev 'c0-6d-ed-d4-5f-df' '10.243.1.8' $SN_C2 'ECI-T44F2' $true 'camera' 3 '2026-11-05 19:09:38' @('exchangecode') @('securityCode')),
  (Dev 'c0-6d-ed-d4-60-aa' '192.168.1.64' $SN_C3 'ECI-T44F2' $false 'camera' 4)
)
$port = 39000 + (Get-Random -Maximum 900)
$fk = Start-Fake $devs $port
$script:SadpTest = '127.0.0.1:' + $port
try {
Write-Host '1. SADP'
Check ([bool]$py) ('a real Python was found for the fake devices (' + $py + ')')
Check $fk.started 'the fake devices started (fake_sadp.py needs only the standard library; 2.2.4 needed the cryptography package)'
$found = @(Find-HikSadp 2.5)
Eq $found.Count 4 'discovery: all 4 devices found, on 3 different subnets, without any address on those subnets'
$nvr = $found | Where-Object { $_.serial -eq $SN_NVR }
Eq $nvr.kind 'nvr' 'NVR recognised (8 channels / ERI- model)'; Eq $nvr.shortSerial 'K53440227' 'NVR short serial for the form = K53440227 (the real one from 3 Hewlett)'
$c1 = $found | Where-Object { $_.serial -eq $SN_C1 }; Eq $c1.kind 'camera' 'camera recognised (1 channel is not an NVR)'; Eq $c1.shortSerial 'K43962989' 'camera short serial = last 9'
Check ($c1.activated -and -not ($found | Where-Object { $_.serial -eq $SN_C3 }).activated) 'activation status read: 3 activated, 1 factory-fresh'
Check ($c1.encrypt -and $c1.salt) 'Encrypt/Salt fields are read (new firmware)'
$e = Request-HikResetExport $c1
Check $e.ok 'export: the device gave its request code'
$f1 = Save-HikResetFile $c1 $e (Join-Path $tmp 'req')
$nf = 'x'; $nerr = ''; try { $nf = Save-HikResetFile $c1 ([pscustomobject]@{ ok = $false; request = $null }) (Join-Path $tmp 'req-null') } catch { $nerr = $_.Exception.Message }
Check ($null -eq $nf -and -not $nerr -and -not (Test-Path (Join-Path $tmp 'req-null'))) 'no request code: Save-HikResetFile writes nothing and does not crash (2.2.4: null-valued expression at HikSadp.ps1:145)'
$txt = [IO.File]::ReadAllText($f1)
Eq $txt ($devs[1].code + $SN_C1) 'request file = code + serial in one line, no newline (the exact shape of SADP 3.1.4.4''s own export)'
Check ($txt -match '^AwAAA[A-Za-z0-9+/]{171}[A-Z]{3}-[A-Z0-9\-]+$') 'request file matches the shape of the 4 real files (AwAAA... 176 base64 chars + serial)'
Eq (Split-Path -Leaf $f1) ('ECI-T44F2-' + $SN_C1 + '.xml') 'file name like SADP''s: <model>-<serial>.xml'
$c2 = $found | Where-Object { $_.serial -eq $SN_C2 }; $e2 = Request-HikResetExport $c2
Check ($e2.ok -and $e2.type -eq 'exchangecode') 'a device that only answers the second form of the ask is still exported (forms tried in order)'
$c3 = $found | Where-Object { $_.serial -eq $SN_C3 }; $e3 = Request-HikResetExport $c3 1.5
Check (-not $e3.ok) 'a not-activated device has no request code (it needs activation, not a reset)'
# import (2.2.3, Codex #6: the fake device speaks the old plain-password forms, which are now the Admin's opt-in only)
$script:SadpAllowPlainPassword = $true
$u = [pscustomobject]@{ kind = 'file'; code = $devs[1].unlock; file = '' }
$r = Import-HikUnlock $c1 $u $PW 2.0
Check $r.ok 'import: the right unlock file + new password is accepted'
Eq (Fake-State $fk).devices[1].password $PW 'the device now holds the new password'
$bad = [pscustomobject]@{ kind = 'file'; code = (New-Code 999); file = '' }
$r2 = Import-HikUnlock $c2 $bad $PW 1.5
Check (-not $r2.ok -and $r2.tries -le 3) 'import: a wrong file is refused and tried at most 3 times (no lock-out risk)'
Check ($r2.error -match 'denied') 'import: the refusal is explained in plain words'
$u2 = [pscustomobject]@{ kind = 'file'; code = $devs[2].unlock; file = '' }
$r3 = Import-HikUnlock $c2 $u2 $PW 2.0
Check ($r3.ok -and $r3.form -eq 'securityCode') 'import: the second public form is tried when the first is not understood'
Write-Host '1b. SADP real reset (key exchange + AES password + 8-character key)'
$rd = @{ mac = 'c0-6d-ed-aa-aa-aa'; ip = '192.168.7.5'; mask = '255.255.255.0'; gw = '192.168.7.1'; serial = 'ECI-T44F220220903AAWRK52336999'; model = 'ECI-T44F2'; activated = $true; kind = 'camera'; boot = '2026-11-05 19:09:38'; code = (New-Code 77); unlock = ''; codeTypes = @('exchangecode'); importTypes = @('x'); password = ''; real = $true; realUnlock = 'f8f8e4f4'; layout = 1 }
$rd2 = @{} + $rd; $rd2.mac = 'c0-6d-ed-aa-aa-bb'; $rd2.serial = 'ECI-T44F220220903AAWRK52336998'; $rd2.layout = 2; $rd2.realUnlock = '6e76566d'
$port2 = $port + 7; $fk2 = Start-Fake @($rd, $rd2) $port2; $keep = $script:SadpTest; $script:SadpTest = '127.0.0.1:' + $port2
$fd = @(Find-HikSadp 2)
$dA = $fd | Where-Object { $_.mac -eq $rd.mac }; $dB = $fd | Where-Object { $_.mac -eq $rd2.mac }
$kx = Invoke-SadpKeyExchange $dA; Check ($kx.ok -and $kx.key.Length -ge 32) 'real reset: the device answers the key exchange and the session key decrypts'
$rBad = Import-HikUnlock $dA ([pscustomobject]@{ kind = 'file'; code = 'deadbeef'; file = '' }) $PW 1.5
Check (-not $rBad.ok) 'real reset: a wrong 8-character key is refused'
$rA = Import-HikUnlock $dA ([pscustomobject]@{ kind = 'file'; code = 'f8f8e4f4'; file = '' }) $PW 2.0
Check $rA.ok 'real reset: right key + password encrypted with the session key is accepted (layout 1)'
Eq (Fake-State $fk2).devices[0].password $PW 'real reset: the device decrypted exactly the new password'
$rB = Import-HikUnlock $dB ([pscustomobject]@{ kind = 'file'; code = '6e76566d'; file = '' }) $PW 2.0
Check ($rB.ok -and $rB.form -eq 'reset/layout2') 'real reset: the second AES layout is tried when the first is not accepted'
Eq (Fake-State $fk2).devices[1].password $PW 'real reset: layout 2 password decrypted too'
Check ($rB.tries -le 2) 'real reset: at most 2 attempts'
Stop-Fake $fk2; $script:SadpTest = $keep
Write-Host '2. flow'
$sp = Join-Path $tmp 'state.json'; $st = Read-HikState $sp
$devs2 = @(Find-HikSadp 2.5)
$exp = @(Export-HikRequests $devs2 (Join-Path $tmp 'req2') $st $sp)
Eq $exp.Count 3 'export: the 3 activated devices (the factory-fresh one is skipped)'
$n1 = @((Fake-State $fk).log | Where-Object { $_.type -in @('getcode', 'exchangecode') }).Count
$exp2 = @(Export-HikRequests $devs2 (Join-Path $tmp 'req2') $st $sp)
$n2 = @((Fake-State $fk).log | Where-Object { $_.type -in @('getcode', 'exchangecode') }).Count
Eq $n2 $n1 'export run again: the devices are NOT asked again (a new request would cancel the first file)'
$st2 = Read-HikState $sp; Eq @($st2.devices).Count 3 'state saved and reloaded: 3 devices'
$d = Get-HikStateDevice $st2 $SN_C1; Eq $d.status 'exported' 'status exported'; Check (([datetime]$d.validUntil) -gt (Get-Date).AddHours(47)) 'valid for 48 hours'
# reply files in the replies folder: right one, own request file, someone else's, and junk
$rep = Join-Path $tmp 'replies'; New-Item -ItemType Directory -Force -Path $rep | Out-Null
$since = (Get-Date).AddMinutes(-5)
[IO.File]::WriteAllText((Join-Path $rep 'unlock.xml'), ($devs[1].unlock + $SN_C1))
[IO.File]::WriteAllText((Join-Path $rep 'other.xml'), ($devs[0].unlock + 'ZZZ-OTHER-DEVICE-123456'))
Copy-Item $f1 (Join-Path $rep ('ECI-T44F2-' + $SN_C1 + '.xml')) -ErrorAction SilentlyContinue
$cfgF = [pscustomobject]@{ mail = [pscustomobject]@{ mode = 'folder' } }
foreach ($x in @($st2.devices)) { if ($x.serial -eq $SN_C1) { $x.status = 'submitted' } }; Save-HikState $sp $st2
$rr = Receive-HikReplies $st2 $sp $cfgF $tmp $rep
Eq @($rr.got).Count 1 'replies: exactly one reply matched (by serial)'; Eq $rr.got[0].serial $SN_C1 'replies: matched to the right camera'
Eq @($rr.unmatched).Count 1 'replies: the file for an unknown device is listed as unmatched, never used'
Check ((Get-HikStateDevice $st2 $SN_C1).status -eq 'replied') 'status replied'
# import step with the login check; the camera must not have restarted
$ok = { param($ip, $p) $true }
$script:SadpAllowPlainPassword = $true   # 2.2.3 (Codex #6): opt-in for the fake device's old forms
$devsNow = @(Find-HikSadp 2)
$done = @(Import-HikReplies $st2 $sp $PW $ok)
Eq $done.Count 1 'import: reset done and the login check passed'; Eq (Get-HikStateDevice $st2 $SN_C1).status 'verified' 'status verified'
# restarted device: its old file must be refused
$d2 = Get-HikStateDevice $st2 $SN_C2; $d2.status = 'replied'; $d2.bootTime = '2026-11-04 01:00:00'; $d2.replyFile = (Join-Path $rep 'unlock.xml'); Save-HikState $sp $st2
$done = @(Import-HikReplies $st2 $sp $PW $ok)
Eq (Get-HikStateDevice $st2 $SN_C2).status 'expired' 'a device that restarted after the request: its file is refused and marked expired (nothing sent to it)'
# expired request
$d3 = Get-HikStateDevice $st2 $SN_NVR; $d3.status = 'replied'; $d3.validUntil = (Get-Date).AddHours(-1).ToString('s'); $d3.replyFile = (Join-Path $rep 'unlock.xml'); Save-HikState $sp $st2
$done = @(Import-HikReplies $st2 $sp $PW $ok); Eq (Get-HikStateDevice $st2 $SN_NVR).status 'expired' 'a request older than 48 hours is refused and marked expired'
# register files that already exist (made by SADP / HiTools earlier)
$st3 = Read-HikState (Join-Path $tmp 'state3.json'); $pre = Join-Path $tmp 'pre'; New-Item -ItemType Directory -Force -Path $pre | Out-Null
[IO.File]::WriteAllText((Join-Path $pre ('ERI-K108-P8-' + $SN_NVR + '.xml')), ((New-Code 7) + $SN_NVR)); [IO.File]::WriteAllText((Join-Path $pre 'junk.xml'), 'nothing')
$reg = @(Register-HikRequestFiles $st3 $pre $devs2 (Join-Path $tmp 'state3.json'))
Eq $reg.Count 1 'register: an existing SADP export is picked up by the serial at its end; a file with no known serial is skipped'
Write-Host '3. mail'
$mdir = Join-Path $tmp 'mail'; New-Item -ItemType Directory -Force -Path $mdir | Out-Null
$unlockBytes = [Text.Encoding]::ASCII.GetBytes($devs[0].unlock + $SN_NVR)
$b64 = [Convert]::ToBase64String($unlockBytes) -replace '(.{76})', "`$1`r`n"
$eml = "From: =?utf-8?Q?Hikvision_Support?= <support@hikvision.com>`r`nTo: moshe@wireitct.com`r`nSubject: Password reset files`r`nMIME-Version: 1.0`r`nContent-Type: multipart/mixed; boundary=`"BND`"`r`n`r`n--BND`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Transfer-Encoding: quoted-printable`r`n`r`nHello, the attached file resets serial K53440227=2E Valid 48 hours.`r`n--BND`r`nContent-Type: application/octet-stream; name=`"reset.xml`"`r`nContent-Disposition: attachment; filename=`"reset.xml`"`r`nContent-Transfer-Encoding: base64`r`n`r`n$b64`r`n--BND--`r`n"
[IO.File]::WriteAllText((Join-Path $mdir '1.eml'), $eml)
$eml2 = "From: someone@hikvision.com`r`nSubject: other`r`nContent-Type: multipart/mixed; boundary=`"B2`"`r`n`r`n--B2`r`nContent-Type: text/plain`r`n`r`nno serial here`r`n--B2`r`nContent-Type: application/xml; name=`"mystery.xml`"`r`nContent-Disposition: attachment; filename=`"mystery.xml`"`r`nContent-Transfer-Encoding: 7bit`r`n`r`nAAAAAAAAAAAA`r`n--B2--`r`n"
[IO.File]::WriteAllText((Join-Path $mdir '2.eml'), $eml2)
# 2.2.0: no IMAP on the site boxes. Mails saved as .eml (the "I got Hik's email" button, the replies folder) are read the same way.
$mm1 = Read-MimeMessage ([IO.File]::ReadAllBytes((Join-Path $mdir '1.eml')))
Eq $mm1.from 'Hikvision Support <support@hikvision.com>' 'mime: encoded sender name decoded'
Eq @($mm1.attachments).Count 1 'mime: one attachment found'; Eq $mm1.attachments[0].name 'reset.xml' 'mime: attachment name'
Check ((Hm-Latin1).GetString($mm1.attachments[0].bytes) -eq ($devs[0].unlock + $SN_NVR)) 'mime: base64 attachment decoded byte for byte'
Check ($mm1.text -match 'K53440227\.') 'mime: quoted-printable text decoded'
$msgs = @(Get-HikFolderMessages $mdir (Get-Date).AddMinutes(-5) | Sort-Object { [string]$_.subject })
Eq $msgs.Count 2 'eml: both saved mails read from the folder'
Eq $msgs[0].attachments[0].name '1-reset.xml' 'eml in a folder: its attachment is taken'
$pend = @([pscustomobject]@{ serial = $SN_NVR; shortSerial = 'K53440227'; mac = 'c0-6d-ed-2b-f3-85' }, [pscustomobject]@{ serial = $SN_C1; shortSerial = 'K43962989'; mac = 'c0-6d-ed-a7-35-7c' })
$mt = Find-HikReplyMatches $pend $msgs
Eq @($mt.matched).Count 1 'match: the NVR file matched by the serial inside it'; Eq $mt.matched[0].device.serial $SN_NVR 'match: right device'
Eq @($mt.unmatched).Count 1 'match: the file with no serial of ours is unmatched'
Eq (Get-HikCodeFromText "Hello,`r`nYour verification code: AB12CD34`r`nThanks") 'AB12CD34' 'code: an 8-character code is read from the mail text'
Eq (Get-HikCodeFromText 'no code in this mail') '' 'code: none when the mail has none'

Write-Host '3b. reply relay (HTTPS, op hikReplyGet; mock relay)'
$RKEY = 'relay-key-' + [guid]::NewGuid().ToString('N')
$rdir = Join-Path $tmp 'relay'; New-Item -ItemType Directory -Force -Path $rdir | Out-Null
([ordered]@{ $SN_NVR = [ordered]@{ kind = 'file'; name = 'reset.xml'; data = [Convert]::ToBase64String($unlockBytes) }; 'K43962989' = [ordered]@{ kind = 'code'; code = 'AB12CD34' } } | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $rdir 'replies.json') -Encoding ASCII
$rport = 42000 + (Get-Random -Maximum 900)
$rp = Start-Py @((Join-Path $fx 'mock_relay.py'), $rport, $rdir, $RKEY)
$end = (Get-Date).AddSeconds(10); $up = $false
while (-not $up -and (Get-Date) -lt $end) { try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $rport); $c.Close(); $up = $true } catch { Start-Sleep -Milliseconds 150 } }
Check $up 'mock relay is up'
$relay = [pscustomobject]@{ url = ('http://127.0.0.1:' + $rport + '/exec'); address = 'hikreset@wireitct.com'; everySec = 60 }
$oldKey = $env:WIREIT_UPLOAD_KEY
try {
  Check (Test-HikRelayUrl 'https://script.google.com/macros/s/AKfy/exec') 'relay address: https is accepted'
  Check (-not (Test-HikRelayUrl 'http://script.google.com/macros/s/AKfy/exec')) 'relay address: plain http to the internet is refused (the key would travel in clear)'
  Check (-not (Test-HikRelayUrl 'ftp://x') -and -not (Test-HikRelayUrl '')) 'relay address: junk and empty are refused'
  Check (Test-HikRelayUrl $relay.url) 'relay address: http to 127.0.0.1 (tests only) is accepted'
  $r = Get-HikRelayReply $relay '' $pend[0]; Check ($r.state -eq 'failed' -and $r.msg -match 'upload key') 'relay: no upload key on this PC -> a plain message, nothing sent'
  $r = Get-HikRelayReply $relay 'wrong-key' $pend[0]; Check ($r.state -eq 'failed' -and $r.msg -match 'Wrong key') 'relay: a wrong key is reported, not ignored'
  $env:WIREIT_UPLOAD_KEY = $RKEY; Eq (Get-HikRelayKey $tmp) $RKEY 'relay key: the box''s upload key is used (test override)'
  $r = Get-HikRelayReply $relay $RKEY ([pscustomobject]@{ serial = 'DS-2CD1000-I20200101AAWRZ00000000'; shortSerial = 'Z00000000' })
  Eq $r.state 'none' 'relay: nothing for that serial yet -> none'
  $r = Get-HikRelayReply $relay $RKEY $pend[1]
  Check ($r.state -eq 'found' -and $r.message.attachments[0].name -like '*-code.txt' -and [Text.Encoding]::ASCII.GetString($r.message.attachments[0].bytes) -eq 'AB12CD34') 'relay: a code reply becomes a small code file for that serial'
  $cp = Join-Path $tmp 'c.txt'; [IO.File]::WriteAllBytes($cp, [byte[]]$r.message.attachments[0].bytes)
  Eq (Read-HikUnlock -Path $cp).code 'AB12CD34' 'relay: the code file imports as Hikvision''s 8-character key'
  $lg = @(Get-Content (Join-Path $rdir 'requests.log') | ForEach-Object { $_ | ConvertFrom-Json })
  Check (@($lg | Where-Object { $_.op -eq 'hikReplyGet' -and $_.serial -and $_.PSObject.Properties['shortSerial'] -and $_.PSObject.Properties['pc'] -and $_.ua -eq 'WireIt-Toolkit' }).Count -eq $lg.Count) 'relay: every request is op hikReplyGet with serial, short serial and PC name'
  Check (-not ((Get-Content (Join-Path $rdir 'requests.log') -Raw) -match 'password')) 'relay: no password field is ever sent'
  'down' | Set-Content (Join-Path $rdir 'mode.txt'); $r = Get-HikRelayReply $relay $RKEY $pend[0]
  Check ($r.state -eq 'failed' -and $r.msg -match 'no answer' -and $r.msg -notmatch [regex]::Escape($RKEY)) 'relay down: reported as failed, key not in the message'
  'junk' | Set-Content (Join-Path $rdir 'mode.txt'); $r = Get-HikRelayReply $relay $RKEY $pend[0]
  Check ($r.state -eq 'failed' -and $r.msg -match 'unreadable') 'relay answers a web page (sign-in page): reported as failed'
  'ok' | Set-Content (Join-Path $rdir 'mode.txt')
  # config: empty config -> relay off -> the button
  $h0 = Get-HikConfig $null
  Check (-not [string]$h0.relay.url -and $h0.relay.address -eq 'hikreset@wireitct.com' -and $h0.waitMinutes -eq 15) 'config: empty config -> relay off, address default hikreset@wireitct.com, wait 15 min'
  $script:HkRelayStatus = $null; $null = Get-HikReplyMessages $h0 $tmp (Join-Path $tmp 'none') (Get-Date).AddDays(-1) @($pend[0])
  $w0 = Format-HikWaitLine $h0 1 15; Check ($w0.text -match 'I got Hik' -and $w0.text -match 'no reply mailbox') 'config empty: the waiting line says there is no mailbox and points to the button'
  $hBad = Get-HikConfig ([pscustomobject]@{ hikReset = [pscustomobject]@{ relay = [pscustomobject]@{ url = 'http://evil.example/exec' } } })
  Check (-not [string]$hBad.relay.url) 'config: an http:// relay address is switched off (never sends the key in clear)'
  $cfgAll = [pscustomobject]@{ form = [pscustomobject]@{ email = 'moshe@wireitct.com'; firstName = 'Moshe' }; hikReset = [pscustomobject]@{ relay = [pscustomobject]@{ url = $relay.url; address = 'hikreset@wireitct.com'; everySec = 60 }; waitMinutes = 20 } }
  $hc = Get-HikConfig $cfgAll $tmp
  Check ($hc.relay.url -eq $relay.url -and $hc.waitMinutes -eq 20 -and $hc.replyTo -eq 'hikreset@wireitct.com') 'config: relay on -> replies go to the relay address'
  Eq (Get-HikFormFor $hc).email 'hikreset@wireitct.com' 'form: Hikvision''s reply address is the relay''s when the relay is on'
  Eq (Get-HikFormFor $h0).email 'moshe@wireitct.com' 'form: with no relay and no "form" in config.json, the Toolkit''s default form details are used (2.2.1, review M5)'
  Eq (Get-HikFormFor (Get-HikConfig ([pscustomobject]@{ form = $cfgAll.form }))).email 'moshe@wireitct.com' 'form: relay off -> the configured email stays'
  # the whole path: Receive-HikReplies asks the relay for each waiting device and files the reply
  $stm = Read-HikState (Join-Path $tmp 's4.json'); $nvrd = Add-HikStateDevice $stm $nvr (Join-Path $tmp 'req2\x.xml') $nvr.bootTime; $nvrd.status = 'submitted'
  $rr = Receive-HikReplies $stm (Join-Path $tmp 's4.json') $hc $tmp (Join-Path $tmp 'rep4') -ForceRelay
  Check ($rr.got.Count -eq 1 -and (Test-Path $rr.got[0].replyFile) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($rr.got[0].replyFile)) -eq [Convert]::ToBase64String($unlockBytes))) 'Receive-HikReplies over the relay: the reply file is saved byte for byte and the device marked replied'
  Check (@($logLines | Where-Object { $_ -match 'reply mailbox' }).Count -ge 1) 'the screen says the reply came from the reply mailbox'
  $w1 = Format-HikWaitLine $hc 1 12; Check ($w1.text -match 'hikreset@wireitct\.com' -and $w1.text -match '12 more min') 'waiting line: names the address and the minutes left'
  'down' | Set-Content (Join-Path $rdir 'mode.txt')
  $stm2 = Read-HikState (Join-Path $tmp 's5.json'); $c1d = Add-HikStateDevice $stm2 $devs[1] (Join-Path $tmp 'req2\y.xml') $devs[1].bootTime; $c1d.status = 'submitted'
  $rr = Receive-HikReplies $stm2 (Join-Path $tmp 's5.json') $hc $tmp (Join-Path $tmp 'rep5') -ForceRelay
  $w2 = Format-HikWaitLine $hc 1 12; Check ($rr.got.Count -eq 0 -and $w2.color -eq 'Yellow' -and $w2.text -match 'Could not check the reply mailbox' -and $w2.text -match 'I got Hik') 'relay failing: the screen says so and points to the button'
  $n0 = @(Get-Content (Join-Path $rdir 'requests.log')).Count; $null = Receive-HikReplies $stm2 (Join-Path $tmp 's5.json') $hc $tmp (Join-Path $tmp 'rep5')
  Eq @(Get-Content (Join-Path $rdir 'requests.log')).Count $n0 'relay: asked at most once a minute (everySec)'
  'ok' | Set-Content (Join-Path $rdir 'mode.txt')
  # the "I got Hik's email" button: a pasted code, then the flow takes it from inbox\hik
  $inb = Join-Path $tmp 'inbox-hik'
  $sv = Save-HikEmailDrop $inb $SN_C1 -Code ' ab12-cd34 '; Check ($sv.ok -and (Test-Path $sv.path) -and (Get-Content $sv.path -Raw) -eq 'ab12cd34') 'button: a pasted code is saved for that serial (spaces and dashes dropped)'
  Check (-not (Save-HikEmailDrop $inb 'bad serial!' -Code 'AB12CD34').ok) 'button: no device picked -> refused'
  Check (-not (Save-HikEmailDrop $inb $SN_C1 -Code '<script>').ok) 'button: junk instead of a code -> refused'
  $ex = Join-Path $tmp 'run.exe'; [IO.File]::WriteAllText($ex, 'MZ'); Check (-not (Save-HikEmailDrop $inb $SN_C1 -File $ex).ok) 'button: a program file is refused'
  $big = Join-Path $tmp 'big.xml'; [IO.File]::WriteAllBytes($big, (New-Object byte[] (3MB))); Check (-not (Save-HikEmailDrop $inb $SN_C1 -File $big).ok) 'button: a file over 2 MB is refused'
  $hOff = Get-HikConfig $null
  $rr = Receive-HikReplies $stm2 (Join-Path $tmp 's5.json') $hOff $tmp (Join-Path $tmp 'rep5') $inb
  Check ($rr.got.Count -eq 1 -and $rr.got[0].serial -eq $SN_C1 -and -not (Test-Path $sv.path)) 'button: the flow takes the dropped code with no mailbox at all, and the drop is used only once'
  Save-HikWaitingList $inb $stm 'Lieber' 'hikreset@wireitct.com'
  $wl = Get-Content (Join-Path $inb 'waiting.json') -Raw
  Check ($wl -notmatch [regex]::Escape($devs[0].unlock) -and $wl -notmatch 'password') 'waiting list for the button: serials only, no codes or passwords'
} finally { try { $rp.Kill() } catch {}; $env:WIREIT_UPLOAD_KEY = $oldKey }
if (-not $NoPortal) {
  Write-Host '4. portal'
  . (Join-Path $tk 'HikPortal.ps1')
  # 2.2.5 fix 8: the browser gets each argument on its own (2.2.3/2.2.4 sent them as one, so no debugging port and no own profile).
  # Checked by starting a real process the same way Start-HikBrowserSession does (Start-Process + Join-HikArgs) and reading back what it got.
  $oldExtra = $script:PortalExtraArgs; $script:PortalExtraArgs = @('--headless=new', '--no-sandbox')
  $tprof = $tmp + '\Jose Maria\Temp\wireit-hik-1a2b3c4d\'; $turl = 'file:///C:/WireIt%20Test/fake form.html?a="b"'
  $ba = @(Get-HikBrowserArgs 33901 $tprof $turl)
  Eq $ba.Count 9 'portal args: one list element per browser argument'
  Check ($ba[0] -eq '--remote-debugging-port=33901' -and $ba[1] -eq ('--user-data-dir=' + $tprof) -and $ba[-1] -eq $turl) 'portal args: debugging port, own profile and page are separate arguments'
  if ($py) {
    $aout = Join-Path $tmp 'argv.json'
    $asp = @{ FilePath = $py; ArgumentList = (Join-HikArgs (@((Join-Path $fx 'argv_dump.py'), $aout) + $ba)); PassThru = $true }; if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) { $asp.WindowStyle = 'Hidden' }
    $ap = Start-Process @asp; if (-not $ap.WaitForExit(15000)) { try { $ap.Kill() } catch {} }
    # 2.2.5 fix 9: Windows PowerShell 5.1's ConvertFrom-Json writes a JSON array as ONE object, so @(text | ConvertFrom-Json) read argv_dump's
    # 9 arguments back as 1 item and the check failed on Windows although the program got all 9. Parsed into a variable first, then unrolled.
    $script:ArgvParse = { param($t) ConvertFrom-Json -InputObject $t }
    function Read-ArgvList([string]$t) { if (-not $t) { return }; $v = & $script:ArgvParse $t; foreach ($i in $v) { $i } }
    $araw = ''; if (Test-Path $aout) { $araw = Get-Content $aout -Raw }
    $got = @(Read-ArgvList $araw)
    Eq $got.Count $ba.Count 'portal args: the started program got one argument per list element'
    Eq (($got | ForEach-Object { '[' + $_ + ']' }) -join ' ') (($ba | ForEach-Object { '[' + $_ + ']' }) -join ' ') 'portal args: a started program receives exactly those arguments (spaces, quotes and the trailing \ survive)'
    $script:ArgvParse = { param($t) Write-Output -NoEnumerate @(ConvertFrom-Json -InputObject $t) }   # what 5.1's ConvertFrom-Json does with an array
    Eq @(& $script:ArgvParse $araw).Count 1 'portal args: the 5.1 read-back behaviour reproduced (@(json-array | ConvertFrom-Json) is ONE item)'
    Eq @(Read-ArgvList $araw).Count $ba.Count '...and the read-back still sees every argument under it'
    $script:ArgvParse = { param($t) ConvertFrom-Json -InputObject $t }
  } else { Check $false 'portal args: no Python to start the argument check' }
  $script:PortalExtraArgs = $oldExtra
  $br = ''; foreach ($c in @('/usr/bin/chromium', '/usr/bin/google-chrome', "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")) { if ($c -and (Test-Path -LiteralPath $c)) { $br = $c; break } }
  if (-not $br) { Write-Host '  skip  no Chrome/Edge here' }
  else {
    $script:PortalBrowser = $br; if ($IsLinux) { $script:PortalExtraArgs = @('--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage') }
    $page = Join-Path $fx 'fake_hik_form.html'; $script:PortalUrl = $(if ($IsLinux) { 'file://' + $page } else { ([uri]$page).AbsoluteUri })
    $s = Start-HikBrowserSession $script:PortalUrl
    Check ($null -ne $s) 'portal: browser window opened with its own throw-away profile'
    if ($s) {
      Check (@(Get-ChildItem -Force -LiteralPath $s.profile -ErrorAction SilentlyContinue).Count -gt 0) 'portal: the browser really writes into that throw-away profile folder'
      Check (Wait-PortalForm $s 30) 'portal: form loaded'
      $form = [pscustomobject]@{ firstName = 'Moshe'; lastName = 'Reichman'; email = 'moshe@wireitct.com'; company = 'WireIt CT LLC'; state = 'Connecticut'; zip = '06710'; businessType = 'Installer' }
      $r = Fill-HikPortalForm $s $form $nvr $f1
      $prob = @(Test-PortalFilled $r $nvr); Eq $prob.Count 0 ('portal: every field reads back what was typed' + $(if ($prob.Count) { ': ' + ($prob -join '; ') } else { '' }))
      Check ($r.serialNo -eq 'ok' -and $r.file -like '*.xml') 'portal: serial typed and the request file attached'
      $lf = Invoke-CdpJs $s.cdp 'window.__looksFilled()'
      $notShown = @('firstName','lastName','email','company','zipCode','serialNo','modelNumber' | Where-Object { -not $lf.$_ })
      Eq ($notShown -join ',') '' 'portal: every field is typed with real key presses (a page that only shows typed values shows them all, model number included)'
      $null = Invoke-CdpJs $s.cdp '(function(){ var i=document.querySelector("form#enquiry-form input[name=modelNumber]"); i.value=""; return 1 })()'
      $rf = @(Restore-PortalFields $s $form $nvr)
      Check (($rf -contains 'modelNumber') -and [string](Invoke-CdpJs $s.cdp 'document.querySelector("form#enquiry-form input[name=modelNumber]").value') -eq [string]$nvr.model) 'portal: a field the page blanked while waiting is typed again'
      $null = Invoke-CdpJs $s.cdp 'setTimeout(function(){document.querySelector("input[name=Verification]").value="ABC123"; document.querySelector("#formSubmit").click()}, 3500); 1'
      Eq (Wait-PortalSubmitted $s 30) 'submitted' 'portal: the person types the picture code + Submit; the Toolkit sees the page accept it'
      $posted = Invoke-CdpJs $s.cdp 'window.__posted ? JSON.stringify(window.__posted) : ""' 5
      Stop-HikBrowserSession $s
    }
    # submit through the flow: the person never comes (nobody types the code) -> not marked submitted
    $script:HkAsk = { param($t) '' }
  }
}
Write-Host '6. plan (Fix this site)'
. (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$ls = Get-Content (Join-Path $fx '..\fixsite\lieber-scan.json') -Raw | ConvertFrom-Json
$ls.nvrs[0] | Add-Member -NotePropertyName login -NotePropertyValue 'unknown' -Force
$pl = New-FsPlan $null $ls
Check ($pl.nvrs[0].steps -contains 'reset') 'plan: an NVR nobody can log in to gets the official Hikvision reset step'
Check (($pl.nvrs[0].why -join ' ') -match "official password reset") 'plan: and says why in plain words'
$ls2 = Get-Content (Join-Path $fx '..\fixsite\lieber-scan.json') -Raw | ConvertFrom-Json
$cam = $ls2.devices | Where-Object { $_.ip -eq '192.168.0.65' }; $cam.login = 'unknown'; $cam | Add-Member -NotePropertyName answers -NotePropertyValue $true -Force
$pl2 = New-FsPlan $null $ls2; $c65 = $pl2.cams | Where-Object { $_.ip -eq '192.168.0.65' }
Check (($c65.steps -contains 'reset') -and ($c65.steps -notcontains 'unplug') -and ($c65.steps -notcontains 'poe')) 'plan: unknown-password camera on the wrong subnet: official reset, NO unplug / power-cycle step'
$fl = @(Format-FsPlan $pl2)
Check (@($fl | Where-Object { $_ -match 'Hikvision''s official password reset, automatic' }).Count -ge 1) 'plan screen: says the reset is automatic and that only the picture check is the tech''s'
Check (-not @($fl | Where-Object { $_ -match 'reset button|power-cycle the camera|unplug' -and $_ -match '65' }).Count) 'plan screen: no reset-button / unplug words for that camera'
Check (-not (Test-RunningAsSystem)) 'portal: the browser is never opened from the SYSTEM account (guard present, test runs as a normal user)'
$chs8 = @(1..8 | ForEach-Object { [pscustomobject]@{ channel = $_; ip = ('192.168.254.' + $_); online = ($_ -in 2, 3) } }); $chs8[4].ip = '10.243.1.8'
Eq (Get-FsFreeNvrChannel $chs8 '192.168.1.24' '10.243.1.8') 5 'NVR slot: the camera''s own old slot is reused (ch5 held its old address)'
# 2.2.3 (Codex #15): an offline slot still holds another camera's configuration: a full NVR gives no slot (put it on by hand)
Eq (Get-FsFreeNvrChannel $chs8 '192.168.1.21') 0 'NVR slot: a full NVR (8 plug-and-play slots) -> no slot: never an offline or online camera''s (2.2.3)'
Eq (Get-FsFreeNvrChannel $chs8 '192.168.1.22' '' @(1)) 0 'NVR slot: still none when ch1 is already taken this run (2.2.3)'
Write-Host '5. secrets'
$all = ($logLines -join "`n")
Check ($all -notmatch [regex]::Escape($PW)) 'the new password is in no log line'
Check ($all -notmatch [regex]::Escape($devs[1].unlock) -and $all -notmatch [regex]::Escape($devs[1].code)) 'no request code or unlock code in any log line'
} finally { Stop-Fake $fk; try { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue } catch {} }
Write-Host ''
Write-Host ($script:pass.ToString() + ' passed, ' + $script:fail + ' failed')
exit $script:fail
