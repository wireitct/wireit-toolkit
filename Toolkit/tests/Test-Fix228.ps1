<# Test-Fix228.ps1 - behavioural tests for 2.2.8 (Hikvision reset-file handling; 3 Hewlett camera .7, Nov 8 2026).
   What happened on site (Toolkit 2.1.0): Hik sent two "Reset Password" emails, one with the xml and one with none; the one with no
   attachment crashed HikMail ("GetString ... Array cannot be null"), then "matches no device here: (no serial or MAC of ours in it)".
   By hand, several xml files and re-exports piled up and every import was refused ("Device refused to process").
   HF1 an email with no attachment / an empty one / a non-xml one is skipped with a plain line; it never throws or stops the others.
   HF2 every export is recorded (serial, time, id); only a reply that arrived AFTER the latest export for that serial is used; older
       ones are named; a new export that would void a pending request is warned about; of several request files, the newest wins.
   HF3 "matches no device" says why: no serial found / serial X not on this site / not waiting.
   HF4 after "device refused", a clear next step: power-cycle, export once, submit that file, import its reply, no re-export.
   Real functions (HikMail, HikResetFlow, HikEmailDrop) and the real HikReset.ps1 entry point. Only SADP (the device's network
   answers) is stood in for. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix228-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Notes($r) { if (Get-Command Show-HikReplyNotes -ErrorAction SilentlyContinue) { Show-HikReplyNotes $r } else { Write-Host '     (no Show-HikReplyNotes in this code)' } }
function Cnt($o, [string]$n) { if ($o -and $o.PSObject.Properties[$n]) { return @($o.$n | Where-Object { $null -ne $_ }).Count }; return -1 }
function Said([string]$rx) { return @($script:said | Where-Object { $_ -match $rx }) }
$SN = 'ECI-T44F220220903AAWRK52336660'; $SH = 'K52336660'; $MAC = '24-0f-9b-11-22-07'
$SN2 = 'ECI-T44F220220903AAWRK52330021'; $SH2 = 'K52330021'; $MAC2 = '24-0f-9b-11-22-21'
$crlf = "`r`n"
function New-Eml([string]$subject, [string]$date, [string]$attName = '', [string]$attText = $null, [string]$attType = 'application/xml') {
  $e = 'From: Hikvision <noreply@hikvision.com>' + $crlf + 'To: moshe@wireitct.com' + $crlf + 'Subject: ' + $subject + $crlf + 'Date: ' + $date + $crlf + 'MIME-Version: 1.0' + $crlf
  if (-not $attName) { return $e + 'Content-Type: text/plain; charset=utf-8' + $crlf + $crlf + 'Dear customer, please find the reset file.' + $crlf }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes([string]$attText))
  return $e + 'Content-Type: multipart/mixed; boundary="BND"' + $crlf + $crlf + '--BND' + $crlf + 'Content-Type: text/plain' + $crlf + $crlf + 'Dear customer.' + $crlf +
    '--BND' + $crlf + 'Content-Type: ' + $attType + '; name="' + $attName + '"' + $crlf + 'Content-Disposition: attachment; filename="' + $attName + '"' + $crlf + 'Content-Transfer-Encoding: base64' + $crlf + $crlf + $b64 + $crlf + '--BND--' + $crlf
}
function RfcDate([datetime]$d) { return ([DateTimeOffset]$d).ToString('ddd, d MMM yyyy HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture).Remove(([DateTimeOffset]$d).ToString('ddd, d MMM yyyy HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture).Length - 3, 1) }
$unlockXml = '<?xml version="1.0" encoding="UTF-8"?><ResetPassword><SerialNumber>' + $SN + '</SerialNumber><Code>Ab3dE5fG</Code></ResetPassword>'

try {
  . (Join-Path $tk 'HikResetFlow.ps1'); . (Join-Path $tk 'HikEmailDrop.ps1')
  $script:HkSubnetCheckOff = $true   # 2.2.9: these devices are stand-ins with made-up addresses (the subnet check is Test-Fix229 HS1)
  $script:said = New-Object System.Collections.ArrayList
  $script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }; $script:HkAsk = { param($t) '' }
  $dev = [pscustomobject]@{ serial = $SN; shortSerial = $SH; mac = $MAC; model = 'ECI-T44F2'; ip = '10.243.1.7'; status = 'submitted' }

  # =====================================================================================
  Write-Host 'HF1. emails with no / empty / non-xml attachments are skipped with a plain line, never a crash'
  $msgs = @(
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-none'; date = ''; text = 'Dear customer'; attachments = $null },
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-zero'; date = ''; text = ''; attachments = @() },
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-empty'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = ($SN + '.xml'); bytes = [byte[]]@(); type = 'application/xml' }) },
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-nullbytes'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = ($SN + '.xml'); bytes = $null; type = 'application/xml' }) },
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-png'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = 'logo.png'; bytes = [byte[]](137, 80, 78, 71); type = 'image/png' }) },
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-bin'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = ($SH + '.dat'); bytes = [byte[]](0, 1, 2, 255, 254, 9, 10, 0); type = 'application/octet-stream' }) },
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-odd'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = ($SN + '.xml'); bytes = [pscustomobject]@{ x = 1 }; type = 'file' }) },
    [pscustomobject]@{ subject = 'Reset Password'; id = 'm-good'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = ($SN + '.xml'); bytes = [Text.Encoding]::ASCII.GetBytes($unlockXml); type = 'application/xml' }) })
  $mr = $null; $threw = ''
  try { $mr = Find-HikReplyMatches @($dev) $msgs } catch { $threw = $_.Exception.Message }
  Check (-not $threw) 'HF1 a batch with no-attachment, empty, non-xml and unreadable attachments does not throw' $threw
  Check ($mr -and @($mr.matched).Count -eq 1 -and $mr.matched[0].src -eq 'm-good') 'HF1 ...and the real key file in the LAST email is still found (the bad ones never stop the others)'
  $sk = @(); if ($mr -and $mr.PSObject.Properties['skipped']) { $sk = @($mr.skipped) }
  Check (@($sk | Where-Object { $_.src -eq 'm-none' -and $_.why -match 'no attachment' }).Count -eq 1 -and @($sk | Where-Object { $_.src -eq 'm-zero' -and $_.why -match 'no attachment' }).Count -eq 1) 'HF1 an email with no attachment is listed as skipped: "it has no attachment"' (($sk | ForEach-Object { $_.src + '=' + $_.why }) -join '; ')
  Check (@($sk | Where-Object { $_.src -in @('m-empty', 'm-nullbytes') -and $_.why -match 'empty' }).Count -eq 2) 'HF1 an empty attachment (0 bytes or none) is skipped: "the file is empty"'
  Check (@($sk | Where-Object { $_.src -in @('m-png', 'm-bin') -and $_.why -match 'not an xml' }).Count -eq 2) 'HF1 a picture or a binary non-xml attachment is skipped: "not an xml file"'
  Check (@($sk | Where-Object { $_.src -eq 'm-odd' -and $_.why -match 'could not be read' }).Count -eq 1) 'HF1 an attachment that cannot be read is skipped: "could not be read"'
  Check ($mr -and -not @($mr.unmatched | Where-Object { [string]$_.name -eq '' -or [string]$_.why -match 'no serial or MAC of ours' }).Count) 'HF1 none of them is reported as "matches no device" (2.1.0 said that about the email with no attachment)'
  # the screen lines: plain, once each
  $script:said.Clear(); $script:HkSaidOnce = @{}
  $fake = [pscustomobject]@{ got = @(); unmatched = @(); stale = @(); skipped = @($sk) }
  Notes $fake; Notes $fake
  Check (@(Said 'Reset Password.*no attachment').Count -eq 1) 'HF1 the screen says once, in plain words, that the email had no attachment (not every few seconds)' (($script:said) -join ' | ')
  Check (-not @(Said '(?i)exception|GetString|null').Count) 'HF1 no exception text on the screen'

  # the real entry point: HikReset.ps1 -Mode Watch with Hik's two emails saved in the replies folder (no-attachment one first)
  $sd = Join-Path $tmp 'hr-watch'; $rep = Join-Path $sd 'replies'; New-Item -ItemType Directory -Force -Path $rep | Out-Null
  $exportAt = (Get-Date).AddMinutes(-10)
  $stw = [pscustomobject]@{ version = 1; site = '3 Hewlett'; created = (Get-Date -Format 's'); devices = @([pscustomobject]@{ serial = $SN; shortSerial = $SH; model = 'ECI-T44F2'; mac = $MAC; ip = '10.243.1.7'; kind = 'camera'; status = 'submitted'; requestFile = (Join-Path $sd 'req.xml'); bootTime = ''; exportedAt = $exportAt.ToString('s'); validUntil = $exportAt.AddHours(48).ToString('s'); submittedAt = $exportAt.AddMinutes(1).ToString('s'); replyFile = ''; note = '' },
      [pscustomobject]@{ serial = $SN2; shortSerial = $SH2; model = 'ECI-T44F2'; mac = $MAC2; ip = '192.168.1.21'; kind = 'camera'; status = 'verified'; requestFile = ''; bootTime = ''; exportedAt = $exportAt.AddDays(-1).ToString('s'); validUntil = $exportAt.AddDays(1).ToString('s'); note = '' }) }
  [IO.File]::WriteAllText((Join-Path $sd 'req.xml'), ('REQCODE' + $SN))
  ($stw | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $sd 'state.json') -Encoding UTF8
  [IO.File]::WriteAllText((Join-Path $rep '1-no-attachment.eml'), (New-Eml 'Reset Password' (RfcDate (Get-Date).AddMinutes(-3))))
  [IO.File]::WriteAllText((Join-Path $rep '2-with-file.eml'), (New-Eml 'Reset Password' (RfcDate (Get-Date).AddMinutes(-2)) ($SN + '.xml') $unlockXml))
  [IO.File]::WriteAllText((Join-Path $rep '3-other-site.xml'), ('<x><SerialNumber>DS-2CD2143G2-I20231111AAWRJ12345678</SerialNumber><Code>Zz9Yy8Xx</Code></x>'))
  [IO.File]::WriteAllText((Join-Path $rep '4-for-the-done-camera.xml'), ('<x><SerialNumber>' + $SN2 + '</SerialNumber><Code>Qq1Ww2Ee</Code></x>'))
  $cfgp = Join-Path $sd 'config.json'; '{"form":{"firstName":"Moshe","lastName":"Reichman","email":"moshe@wireitct.com","company":"WireIt CT LLC"}}' | Set-Content $cfgp
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tk 'HikReset.ps1') -Mode Watch -StateDir $sd -ConfigPath $cfgp -WaitMinutes 0 2>&1 | Out-String
  $code = $LASTEXITCODE; $ErrorActionPreference = $prev
  $sw = $null; try { $sw = Get-Content (Join-Path $sd 'state.json') -Raw | ConvertFrom-Json } catch {}
  $d7 = $null; if ($sw) { $d7 = @($sw.devices | Where-Object { $_.serial -eq $SN })[0] }
  Check ($code -eq 0 -and $out -notmatch '(?i)exception|GetString|cannot be null') ('HF1 HikReset.ps1 Watch with Hik''s two emails (one with no attachment, first): no crash (exit ' + $code + ')') $out
  Check ($d7 -and $d7.status -eq 'replied') 'HF1 ...and the key file from the other email IS used (camera .7 replied)' $out
  Check ($out -match '(?m)Reset Password.*no attachment.*skipped|skipped.*Reset Password.*no attachment') 'HF1 ...and the screen names the email with no attachment as skipped' $out

  # =====================================================================================
  Write-Host 'HF3. "matches no device" says why'
  Check ($out -match 'DS-2CD2143G2-I20231111AAWRJ12345678.*not (a device )?on this site|not on this site.*DS-2CD2143G2-I20231111AAWRJ12345678') 'HF3 a file for a serial that is not on this site says "serial X ... not on this site"' $out
  Check ($out -match ($SN2 + '.*not waiting')) 'HF3 a file for a camera of this site that is not waiting for a reply says so (and its status)' $out
  $u = Find-HikReplyMatches @($dev) @([pscustomobject]@{ subject = 'Reset Password'; id = 'm1'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = 'reset.xml'; bytes = [Text.Encoding]::ASCII.GetBytes('<x><Code>Ab3dE5fG</Code></x>'); type = 'file' }) })
  Check (@($u.unmatched).Count -eq 1 -and $u.unmatched[0].why -match 'no serial or MAC found') ('HF3 a file with no serial in its name or contents says "no serial or MAC found" (' + [string]@($u.unmatched)[0].why + ')')
  $u2 = Find-HikReplyMatches @($dev) @([pscustomobject]@{ subject = 'Reset Password'; id = 'm2'; date = ''; text = ''; attachments = @([pscustomobject]@{ name = 'DS-2CD2143G2-I20231111AAWRJ12345678.xml'; bytes = [Text.Encoding]::ASCII.GetBytes('<x/>'); type = 'file' }) }) @($dev)
  Check (@($u2.unmatched).Count -eq 1 -and $u2.unmatched[0].why -match 'DS-2CD2143G2-I20231111AAWRJ12345678' -and $u2.unmatched[0].why -match 'not on this site') ('HF3 the serial is read from the file name too (' + [string]@($u2.unmatched)[0].why + ')')
  $script:said.Clear(); $script:HkSaidOnce = @{}
  Notes ([pscustomobject]@{ got = @(); unmatched = @($u.unmatched); stale = @(); skipped = @() })
  Check (@(Said 'matches no device here: reset\.xml.*no serial or MAC found').Count -eq 1) 'HF3 the screen line names the file and the reason' (($script:said) -join ' | ')

  # =====================================================================================
  Write-Host 'HF2. every export is recorded; only a reply AFTER the latest export is used; older ones are named'
  $script:exportN = 0
  function Request-HikResetExport($d) { $script:exportN++; return [pscustomobject]@{ ok = $true; type = 'file'; raw = ''; request = [pscustomobject]@{ value = ('REQ' + $script:exportN + 'X') }; bootTime = $d.bootTime; error = '' } }
  $sp = Join-Path $tmp 'hf2/state.json'; $st = Read-HikState $sp; $rq = Join-Path $tmp 'hf2/requests'
  $live = [pscustomobject]@{ serial = $SN; shortSerial = $SH; mac = $MAC; model = 'ECI-T44F2'; ip = '10.243.1.7'; kind = 'camera'; activated = $true; bootTime = '2026-11-08 21:08:00'; salt = ''; encrypt = $false }
  $null = Export-HikRequests @($live) $rq $st $sp
  $ex = @(); if ($st.PSObject.Properties['exports']) { $ex = @($st.exports) }
  Check ($ex.Count -eq 1 -and $ex[0].serial -eq $SN -and $ex[0].at -and $ex[0].id) ('HF2 the export is recorded: serial, time and an export id (' + $ex.Count + ' record(s))')
  $d = Get-HikStateDevice $st $SN
  Check ($d -and $d.PSObject.Properties['exportId'] -and $ex.Count -and $d.exportId -eq $ex[0].id) 'HF2 the device row names the export it is waiting on'
  # it was sent to Hikvision; now someone re-exports (-Redo): that voids the pending request
  Set-HikStateField $d 'status' 'submitted'; Set-HikStateField $d 'submittedAt' (Get-Date -Format 's'); Save-HikState $sp $st
  $script:said.Clear()
  Start-Sleep -Milliseconds 1100
  $null = Export-HikRequests @($live) $rq $st $sp -Redo
  Check (@(Said '(?i)void|cancel').Count -ge 1 -and @(Said '(?i)(void|cancel).*sent to Hikvision|sent to Hikvision.*(void|cancel)').Count -ge 1) 'HF2 a new export while a request is waiting at Hikvision is warned about plainly (it voids that request)' (($script:said) -join ' | ')
  $ex = @($st.exports)
  Check ($ex.Count -eq 2 -and $ex[0].id -ne $ex[1].id -and (Get-HikStateDevice $st $SN).exportId -eq $ex[1].id) 'HF2 ...both exports are on record, and the device now waits on the newest one'
  $d = Get-HikStateDevice $st $SN; Set-HikStateField $d 'status' 'submitted'; Save-HikState $sp $st
  $latest = [datetime]$d.exportedAt
  # a reply in the replies folder that arrived BEFORE the latest export (the stale 8:43 file)
  $rep2 = Join-Path $tmp 'hf2/replies'; New-Item -ItemType Directory -Force -Path $rep2 | Out-Null
  $old = Join-Path $rep2 ($SN + '.xml'); [IO.File]::WriteAllText($old, $unlockXml); (Get-Item $old).LastWriteTime = $latest.AddMinutes(-17)
  $script:said.Clear(); $script:HkSaidOnce = @{}
  $cfgF = Get-HikConfig $null
  $rr = Receive-HikReplies $st $sp $cfgF $tmp $rep2
  Check (@($rr.got).Count -eq 0 -and (Get-HikStateDevice $st $SN).status -eq 'submitted') 'HF2 a reply that arrived before the latest export is NOT used (the camera would refuse it)'
  $stl = @(); if ($rr.PSObject.Properties['stale']) { $stl = @($rr.stale) }
  Check ($stl.Count -eq 1 -and $stl[0].why -match 'before' -and $stl[0].serial -eq $SN) 'HF2 ...it is listed as stale, with the reason' (($stl | ForEach-Object { $_.why }) -join '; ')
  Notes $rr
  Check (@(Said ('(?i)not used.*' + [regex]::Escape($SH) + '|' + [regex]::Escape($SN) + '.*not used')).Count -ge 1 -and @(Said '(?i)older request|before the latest').Count -ge 1) 'HF2 ...and the screen names it and says it answers an older request' (($script:said) -join ' | ')
  # an old email saved as .eml, its Date header before the export, file written now: the mail's own date counts
  Remove-Item $old -Force
  [IO.File]::WriteAllText((Join-Path $rep2 'old.eml'), (New-Eml 'Reset Password' (RfcDate $latest.AddMinutes(-20)) ($SN + '.xml') $unlockXml))
  $rr = Receive-HikReplies $st $sp $cfgF $tmp $rep2
  Check (@($rr.got).Count -eq 0 -and (Cnt $rr 'stale') -eq 1) 'HF2 an email saved now whose Date is before the latest export is stale too (its own date counts, not the file''s)'
  Remove-Item (Join-Path $rep2 'old.eml') -Force
  # the reply to the latest export
  $new = Join-Path $rep2 'fresh.eml'; [IO.File]::WriteAllText($new, (New-Eml 'Reset Password' (RfcDate $latest.AddSeconds(2)) ($SN + '.xml') $unlockXml))
  $rr = Receive-HikReplies $st $sp $cfgF $tmp $rep2
  $d = Get-HikStateDevice $st $SN
  Check (@($rr.got).Count -eq 1 -and $d.status -eq 'replied') 'HF2 the reply that came after the latest export is used'
  Check ($d.PSObject.Properties['replyForExport'] -and $d.replyForExport -eq $ex[1].id) 'HF2 ...and the state says which export it answers'
  # the relay: an answer older than the export is not used either (a relay that does not filter yet)
  . (Join-Path $tk 'HikMail.ps1')
  $d.status = 'submitted'; Save-HikState $sp $st
  function Get-HikRelayReply($Relay, $Key, $Device, $TimeoutSec = 20) { return [pscustomobject]@{ state = 'found'; msg = ''; message = [pscustomobject]@{ from = 'relay'; subject = 'Reset Password'; date = $latest.AddMinutes(-30).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); text = ''; attachments = @([pscustomobject]@{ name = ('relay-' + $SN + '-x.xml'); bytes = [Text.Encoding]::ASCII.GetBytes($unlockXml); type = 'file' }); id = ('relay:' + $Device.serial) } } }
  function Get-HikRelayKey($d) { return 'k' }
  $cfgR = Get-HikConfig ([pscustomobject]@{ hikReset = [pscustomobject]@{ relay = [pscustomobject]@{ url = 'https://script.google.com/macros/s/x/exec' } } })
  $rr = Receive-HikReplies $st $sp $cfgR $tmp (Join-Path $tmp 'hf2/rep-relay') -ForceRelay
  Check (@($rr.got).Count -eq 0 -and (Cnt $rr 'stale') -eq 1) 'HF2 a relay answer received before the latest export is not used'
  $script:relayAt = $latest.AddSeconds(-30)
  function Get-HikRelayReply($Relay, $Key, $Device, $TimeoutSec = 20) { return [pscustomobject]@{ state = 'found'; msg = ''; message = [pscustomobject]@{ from = 'relay'; subject = 'Reset Password'; date = $script:relayAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); text = ''; attachments = @([pscustomobject]@{ name = ('relay-' + $SN + '-x.xml'); bytes = [Text.Encoding]::ASCII.GetBytes($unlockXml); type = 'file' }); id = ('relay:' + $Device.serial) } } }
  $rr = Receive-HikReplies $st $sp $cfgR $tmp (Join-Path $tmp 'hf2/rep-relay') -ForceRelay
  Check (@($rr.got).Count -eq 1 -and (Cnt $rr 'stale') -eq 0) 'HF2 ...but a mail stamped 30 s before the export (the mail server''s clock vs this PC''s) is still used'
  $d.status = 'submitted'; Save-HikState $sp $st
  $script:relayAt = $latest.AddMinutes(-3)
  $rr = Receive-HikReplies $st $sp $cfgR $tmp (Join-Path $tmp 'hf2/rep-relay2') -ForceRelay
  Check (@($rr.got).Count -eq 0 -and (Cnt $rr 'stale') -eq 1) 'HF2 ...and one 3 minutes before the export (a reply to the voided request) is not'
  . (Join-Path $tk 'HikMail.ps1')

  $repOwn = Join-Path $tmp 'hf2/rep-own'; New-Item -ItemType Directory -Force -Path $repOwn | Out-Null
  [IO.File]::WriteAllText((Join-Path $repOwn ('reply-' + $SN2 + '.xml')), ('<x><SerialNumber>' + $SN2 + '</SerialNumber></x>'))
  $rr = Receive-HikReplies $st $sp $cfgF $tmp $repOwn
  Check (-not @($rr.unmatched).Count) 'HF3 a reply this Toolkit saved itself earlier (replies\reply-<serial>.xml of another camera) is not reported as "matches no device"'
  # a drop ("I got Hik's email") of an old Downloads file keeps that file's time, so it is named stale and moved out of the way
  $inb = Join-Path $tmp 'hf2/inbox'; $dl = Join-Path $tmp 'hf2/Downloads'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
  $dlf = Join-Path $dl ($SN + ' (2).xml'); [IO.File]::WriteAllText($dlf, $unlockXml); (Get-Item $dlf).LastWriteTime = $latest.AddHours(-3)
  $dr = Save-HikEmailDrop $inb $SN $dlf
  Check ($dr.ok -and ((Get-Item $dr.path).LastWriteTime - $latest.AddHours(-3)).TotalSeconds -lt 2) 'HF2 a dropped file keeps the time it was downloaded (not the time it was dropped)'
  $rr = Receive-HikReplies $st $sp $cfgF $tmp (Join-Path $tmp 'hf2/rep-empty') $inb
  Check (@($rr.got).Count -eq 0 -and (Cnt $rr 'stale') -eq 1 -and -not (Test-Path -LiteralPath $dr.path)) 'HF2 ...a drop older than the latest export (even by hours) is named stale, not used, and taken out of the inbox' ((@($rr.stale) | ForEach-Object { $_.why }) -join ';')
  Check (@(Get-ChildItem -LiteralPath (Join-Path $inb 'not-used') -File -ErrorAction SilentlyContinue).Count -eq 1) 'HF2 ...kept in inbox\hik\not-used for a look, never re-read'

  # several SADP exports for one camera in one folder: the NEWEST is the one in force; the older ones are named
  $sp3 = Join-Path $tmp 'hf2/state3.json'; $st3 = Read-HikState $sp3; $pile = Join-Path $tmp 'hf2/pile'; New-Item -ItemType Directory -Force -Path $pile | Out-Null
  $fa = Join-Path $pile ('a-' + $SN + '.xml'); [IO.File]::WriteAllText($fa, ('NEWCODE' + $SN)); (Get-Item $fa).LastWriteTime = (Get-Date).AddMinutes(-2)
  $fb = Join-Path $pile ('b-' + $SN + '.xml'); [IO.File]::WriteAllText($fb, ('OLDCODE' + $SN)); (Get-Item $fb).LastWriteTime = (Get-Date).AddMinutes(-25)
  $script:said.Clear()
  $null = Register-HikRequestFiles $st3 $pile @($live) $sp3
  Check ((Get-HikStateDevice $st3 $SN).requestFile -eq $fa) 'HF2 of two request files for one camera, the newest export is the one used (2.2.7 took the last by name)' ([string](Get-HikStateDevice $st3 $SN).requestFile)
  Check (@(Said ('(?i)b-' + [regex]::Escape($SN) + '\.xml.*(older|newer)')).Count -ge 1) 'HF2 ...and the older one is named as not used' (($script:said) -join ' | ')

  # =====================================================================================
  Write-Host 'HF4. "device refused": a clear next step, and the refused file is not offered again'
  function Find-HikSadp($s) { return @([pscustomobject]@{ mac = $MAC; ip = '10.243.1.7'; bootTime = '2026-11-08 21:08:00'; serial = $SN }) }
  function Read-HikUnlock([string]$f) { return [pscustomobject]@{ kind = 'file'; code = 'Ab3dE5fG'; file = $f } }
  function Import-HikUnlock($l, $u, $pw) { return [pscustomobject]@{ ok = $false; result = 'failed'; form = ''; tries = 2; error = 'the device answered "failed"' } }
  $d = Get-HikStateDevice $st $SN; $d.status = 'replied'; $d.bootTime = '2026-11-08 21:08:00'; $d.replyFile = (Join-Path $rep2 'x.xml'); Save-HikState $sp $st
  $script:said.Clear()
  $done = @(Import-HikReplies $st $sp 'Site-Pass-1234' { param($ip, $p) $false })
  $all = ($script:said) -join ' | '
  Check ($done.Count -eq 0 -and $all -match '(?i)refused') 'HF4 the refusal is said as a refusal' $all
  Check ($all -match '(?i)power.?cycle' -and $all -match '(?i)export (only )?once|ONE new request|one new request' -and $all -match '(?i)submit|send that file|Hikvision''s page' -and $all -match '(?i)import' -and $all -match '(?i)(not|never|no) .*export(ing)? again|without (re-?)?exporting|no new export') 'HF4 ...with the next step: power-cycle, export once, submit that file, import its reply, no re-export in between' $all
  Check ($all -notmatch '(?i)Forgot password, Import file, pick') 'HF4 ...and it does NOT tell the tech to import the same refused file again in SADP' $all
  Check ((Get-HikStateDevice $st $SN).status -eq 'refused') 'HF4 the device is marked "refused", so that file is not imported again'
  $script:said.Clear()
  $live2 = [pscustomobject]@{ serial = $SN; shortSerial = $SH; mac = $MAC; model = 'ECI-T44F2'; ip = '10.243.1.7'; kind = 'camera'; activated = $true; bootTime = '2026-11-08 21:30:00'; salt = ''; encrypt = $false }
  $null = Export-HikRequests @($live2) $rq $st $sp
  Check ((Get-HikStateDevice $st $SN).status -eq 'exported' -and -not @(Said '(?i)void').Count) 'HF4 after the power-cycle the next run makes ONE fresh export, with no "void" warning (nothing valid was pending)' (($script:said) -join ' | ')
  # an import that got no answer at all is not a refusal: the old SADP hint stays
  function Import-HikUnlock($l, $u, $pw) { return [pscustomobject]@{ ok = $false; result = ''; form = ''; tries = 1; error = 'the device did not answer the reset' } }
  $d = Get-HikStateDevice $st $SN; $d.status = 'replied'; $d.bootTime = '2026-11-08 21:08:00'; Save-HikState $sp $st
  $script:said.Clear(); $null = @(Import-HikReplies $st $sp 'Site-Pass-1234' { param($ip, $p) $false })
  Check ((Get-HikStateDevice $st $SN).status -eq 'replied' -and @(Said 'Finish this one in SADP').Count -eq 1) 'HF4 a device that did not answer at all keeps its reply (not marked refused) and gets the SADP hint as before'
  $flow = [IO.File]::ReadAllText((Join-Path $tk 'HikResetFlow.ps1'))
  Check ($flow -match "'refused'\s*\{[^}]*(?i)power") 'HF4 Fix this site''s end-of-run list says what to do for a refused camera (power-cycle, then one new request)'

  # =====================================================================================
  Write-Host 'version'
  $v = @(([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'ToolkitCore.ps1')), "TkBuiltVersion = '([0-9.]+)'")).Groups[1].Value, ([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'FixSiteCore.ps1')), "FsVersion = '([0-9.]+)'")).Groups[1].Value, ([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'FixSiteBw.ps1')), "FsVersion = '([0-9.]+)'")).Groups[1].Value, [string](Get-Content (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json).version)
  Check ((($v | Select-Object -Unique) -join ',') -eq '2.2.18') ('version 2.2.18 (2.2.18: bumped from 2.2.17) in ToolkitCore, FixSiteCore, FixSiteBw and version.json (' + ($v -join ',') + ')')
} catch {
  $script:fail++; Write-Host ('FAIL the suite stopped: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Fix228: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $(if ($script:fail) { 1 } else { 0 })
