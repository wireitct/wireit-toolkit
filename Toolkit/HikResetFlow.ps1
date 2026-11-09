<#
 HikResetFlow.ps1 - WireIt Toolkit 2.2: Hikvision's official password reset, as ONE automatic flow.
   find (SADP, any subnet) -> export each device's request file -> fill + attach on Hikvision's reset page (you type the picture code)
   -> ask the reply relay (HTTPS, by serial; no mail password on the PC) and the "I got Hik's email" drops -> match each returned unlock file to its serial -> import it (SADP) with the site password -> check the login.
 The state of every device is kept in a small file (state.json) so the flow can stop (the reply takes time) and carry on later:
   exported -> submitted -> replied -> imported -> verified            (or: failed, with the reason)
 Official path only. No guessing, no default passwords, no exploits, nothing sent anywhere except Hikvision's own page and your own mailbox.
 Dot-sourced by HikReset.ps1 (command line), FixSite.ps1 (the wizard) and the tests.
#>
$here0 = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here0 'HikSadp.ps1')
. (Join-Path $here0 'HikPortal.ps1')
. (Join-Path $here0 'HikMail.ps1')

$script:HkSay = { param($t, $c) Write-Host $t }
$script:HkAsk = { param($t) Read-Host $t }
$script:HkStatus = $null       # 2.2.0: optional: gets the waiting state for a screen (2.2.3: nothing sets it in the Toolkit)
function Hk-Say([string]$t, [string]$c = '') { & $script:HkSay $t $c }
function Hk-Ask([string]$t) { return (& $script:HkAsk $t) }
$script:HkValidHours = 48

# ---------------- state ----------------
function Read-HikState([string]$Path) {
  if (Test-Path -LiteralPath $Path) { try { $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json; if ($o -and $o.PSObject.Properties['devices']) { $o.devices = @($o.devices | Where-Object { $null -ne $_ }); if ($o.PSObject.Properties['exports']) { $o.exports = @($o.exports | Where-Object { $null -ne $_ }) } else { $o | Add-Member -NotePropertyName exports -NotePropertyValue @() -Force }; return $o } } catch {} }
  return [pscustomobject]@{ version = 1; site = ''; created = (Get-Date -Format 's'); devices = @(); exports = @() }
}
function Save-HikState([string]$Path, $State) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Get-HikStateDevice($State, [string]$Serial) { foreach ($d in @($State.devices)) { if ($d.serial -eq $Serial) { return $d } }; return $null }
function Set-HikStateField($d, [string]$Name, $Value) { if ($d.PSObject.Properties[$Name]) { $d.$Name = $Value } else { $d | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force } }
# 2.2.8: every request file made (or registered) is recorded: serial, when, an export id (the first 12 hex of the file's SHA-256),
# the file and the boot time. Hikvision's reply only fits the LATEST export of a device: each new export voids the one before
# (3 Hewlett, Nov 8 2026: re-exports between replies, every import "Device refused to process").
function Get-HikExportId([string]$File) {
  try { $sha = [Security.Cryptography.SHA256]::Create(); try { $h = $sha.ComputeHash([IO.File]::ReadAllBytes($File)) } finally { $sha.Dispose() }; return (-join ($h[0..5] | ForEach-Object { $_.ToString('x2') })) } catch { return '' }
}
function Add-HikExportRecord($State, $Dev, [string]$File, [string]$BootTime, [datetime]$At) {
  if (-not $State.PSObject.Properties['exports']) { $State | Add-Member -NotePropertyName exports -NotePropertyValue @() -Force }
  $rec = [pscustomobject]@{ serial = [string]$Dev.serial; at = $At.ToString('s'); id = (Get-HikExportId $File); file = $File; bootTime = $BootTime }
  $State.exports = @(@($State.exports | Where-Object { $null -ne $_ }) + @($rec) | Select-Object -Last 100)
  return $rec
}
function Get-HikExports($State, [string]$Serial) { if (-not $State.PSObject.Properties['exports']) { return @() }; return @($State.exports | Where-Object { $_ -and [string]$_.serial -eq $Serial }) }
function Add-HikStateDevice($State, $Dev, [string]$File, [string]$BootTime, $At = $null) {
  $d = Get-HikStateDevice $State $Dev.serial
  $now = $(if ($At) { [datetime]$At } else { Get-Date })
  $rec = Add-HikExportRecord $State $Dev $File $BootTime $now
  $row = [ordered]@{ serial = $Dev.serial; shortSerial = $Dev.shortSerial; model = $Dev.model; mac = $Dev.mac; ip = $Dev.ip; kind = $Dev.kind; salt = $Dev.salt; encrypt = [bool]$Dev.encrypt; requestFile = $File; bootTime = $BootTime
    exportedAt = $now.ToString('s'); validUntil = $now.AddHours($script:HkValidHours).ToString('s'); exportId = $rec.id; status = 'exported'; submittedAt = ''; replyFile = ''; replyFrom = ''; replyAt = ''; replyForExport = ''; importedAt = ''; verifiedAt = ''; note = '' }
  if ($d) { foreach ($k in $row.Keys) { Set-HikStateField $d $k $row[$k] }; return $d }
  $State.devices = @($State.devices) + @([pscustomobject]$row); return (Get-HikStateDevice $State $Dev.serial)
}
# 2.2.8: the plain warning when a NEW export would void a request that is still waiting at Hikvision ('' = nothing to warn about)
function Get-HikVoidWarning($Cur, $Dev = $null) {
  if (-not $Cur -or [string]$Cur.status -notin @('submitted', 'replied')) { return '' }
  $when = ''; try { $when = ([datetime]$Cur.exportedAt).ToString('h:mm tt') } catch {}
  $who = ([string]$Cur.model + ' ' + [string]$Cur.ip + ' (serial ' + [string]$Cur.serial + ')').Trim()
  if ($Dev -and $Cur.bootTime -and $Dev.bootTime -and [string]$Dev.bootTime -ne [string]$Cur.bootTime) { return ('  ' + $who + ' restarted since its request from ' + $when + ', so that request (and any reply to it) no longer works. Making one new request file.') }
  try { if (([datetime]$Cur.validUntil) -lt (Get-Date)) { return ('  ' + $who + ': the request from ' + $when + ' is older than 48 hours and no longer works. Making one new request file.') } } catch {}
  $sent = $(if ([string]$Cur.status -eq 'replied') { 'sent to Hikvision and answered' } else { 'sent to Hikvision' })
  return ('  WARNING ' + $who + ': a new request file VOIDS the one from ' + $when + ' that was ' + $sent + '. Hikvision''s reply to that one will then be refused by the device. Use only the reply to the NEW file, and do not export again after it.')
}

# ---------------- 1. find + export ----------------
# $Devices = Find-HikSadp result. A device that is not activated has no password to reset: it is only activated (the caller does that).
function Export-HikRequests($Devices, [string]$OutDir, $State, [string]$StatePath, [switch]$Redo) {
  $made = @()
  foreach ($dev in @($Devices | Where-Object { $_.activated })) {
    $cur = Get-HikStateDevice $State $dev.serial
    if ($cur -and -not $Redo -and $cur.status -in @('exported', 'submitted', 'replied') -and (Test-Path -LiteralPath $cur.requestFile) -and ([datetime]$cur.validUntil) -gt (Get-Date) -and $cur.bootTime -eq $dev.bootTime) {
      Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': request file from ' + ([datetime]$cur.exportedAt).ToString('h:mm tt') + ' is still good - not asking the device again (a new one would cancel it).'); $made += $cur; continue
    }
    $vw = Get-HikVoidWarning $cur $dev; if ($vw) { Hk-Say $vw $(if ($vw -match 'WARNING') { 'Red' } else { 'Yellow' }) }
    $e = Request-HikResetExport $dev
    if (-not $e.ok) { Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': could not read its request code - ' + $e.error) 'Yellow'; if ($cur) { Set-HikStateField $cur 'note' $e.error }; continue }
    $f = Save-HikResetFile $dev $e $OutDir
    if (-not $f) { Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': its answer had no request code - no file saved') 'Yellow'; continue }
    $d = Add-HikStateDevice $State $dev $f $dev.bootTime
    Save-HikState $StatePath $State
    Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + '  serial ' + $dev.serial + ': request file saved (' + (Split-Path -Leaf $f) + ')') 'Green'
    $made += $d
  }
  return $made
}

# ---------------- 2. Hikvision's page ----------------
function Submit-HikRequests($State, [string]$StatePath, $Form, [int]$PerDeviceTimeoutSec = 900, $Only = $null) {
  # 2.2.1 (review H7): $Only = the serials this run may act on (the approved targets); an old saved device outside it is left alone
  $todo = @($State.devices | Where-Object { $_.status -eq 'exported' -and ($null -eq $Only -or @($Only) -contains [string]$_.serial) })
  if (-not $todo.Count) { Hk-Say 'Nothing waiting to be sent to Hikvision.'; return @() }
  $sent = @(); $n = 0
  $exe = Find-HikBrowser
  foreach ($d in $todo) {
    $n++
    if (-not (Test-Path -LiteralPath $d.requestFile)) { Set-HikStateField $d 'note' 'request file missing'; continue }
    if (([datetime]$d.validUntil) -lt (Get-Date)) { Set-HikStateField $d 'status' 'expired'; Set-HikStateField $d 'note' 'older than 48 hours - export again'; Save-HikState $StatePath $State; Hk-Say ($d.model + ' ' + $d.ip + ': the request file is older than 48 hours - it needs a new export.') 'Yellow'; continue }
    Hk-Say ''
    Hk-Say ('[' + $n + '/' + $todo.Count + '] ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ', form serial ' + $d.shortSerial + ')') 'Cyan'
    $ok = $false
    if ($exe) {
      $s = Start-HikBrowserSession $script:PortalUrl
      if ($s) {
        try {
          if (-not (Wait-PortalForm $s 60)) { Hk-Say 'Hikvision''s page did not load the form. Check the internet on this PC.' 'Yellow' }
          else {
            $r = Fill-HikPortalForm $s $Form $d $d.requestFile
            $bad = @(Test-PortalFilled $r $d)
            if ($bad.Count) { Hk-Say ('  Form filled, but check: ' + ($bad -join '; ')) 'Yellow' } else { Hk-Say ('  Form filled in: ' + $Form.firstName + ' ' + $Form.lastName + ', ' + $Form.company + ', ' + $Form.email + ', serial ' + $d.shortSerial + ', file attached.') 'Green' }
            Hk-Say '  YOUR STEP: type the picture code in the browser window and press Submit. (The code is there to tell a person from a program, so the Toolkit leaves it to you.)' 'Cyan'
            $res = Wait-PortalSubmitted $s $PerDeviceTimeoutSec $null ({ $f = @(Restore-PortalFields $s $Form $d); if ($f.Count) { Hk-Say ('  (the page cleared ' + ($f -join ', ') + ' - filled again)') } }.GetNewClosure())
            if ($res -eq 'submitted') { $ok = $true; Set-HikStateField $d 'status' 'submitted'; Set-HikStateField $d 'submittedAt' (Get-Date -Format 's'); Hk-Say ('  Hikvision accepted it. The reply goes to ' + $Form.email) 'Green' }
            else { Hk-Say ('  Not submitted (' + $res + '). Run it again to retry this one.') 'Yellow' }
          }
        } finally { Stop-HikBrowserSession $s }
      } else { Hk-Say '  Could not open the browser window.' 'Yellow' }
    }
    if (-not $ok -and -not $exe) {
      # no Chrome/Edge: open the page in whatever browser is default, with the values on screen (copy + paste)
      Hk-Say ('  No Chrome or Edge found. Opening the page in your browser. Fill it with: ' + $Form.firstName + ' ' + $Form.lastName + ' / ' + $Form.email + ' / ' + $Form.company + ' / ' + $Form.state + ' / ' + $Form.zip + ' / ' + $Form.businessType + ' / serial ' + $d.shortSerial + ' / model ' + $d.model + ' / file ' + $d.requestFile) 'Yellow'
      try { Start-Process $script:PortalUrl } catch {}
      $a = Hk-Ask '  When Hikvision says it is sent, press Enter (S = skip this one)'
      if ($a -notmatch '^(?i)s') { $ok = $true; Set-HikStateField $d 'status' 'submitted'; Set-HikStateField $d 'submittedAt' (Get-Date -Format 's') }
    }
    Save-HikState $StatePath $State
    if ($ok) { $sent += $d }
  }
  return $sent
}

# ---------------- registering request files that already exist (made by SADP / HiTools / an earlier run) ----------------
# SADP's own export is one line: <code><DeviceSN>. The serial at the end names the device; $Devices (Find-HikSadp) gives the rest.
function Register-HikRequestFiles($State, [string]$Dir, $Devices, [string]$StatePath) {
  # 2.2.8: several exports of one device in a folder (Downloads, Nov 8 2026): only the NEWEST is in force (each export voids the one
  # before), so files are taken oldest first and the newest per serial wins; each older one is named as not used.
  $added = @(); $bySerial = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Filter *.xml -ErrorAction SilentlyContinue | Sort-Object LastWriteTime, Name)) {
    $t = ''; try { $t = [IO.File]::ReadAllText($f.FullName).Trim() } catch { Hk-Say ('  ' + $f.Name + ': could not be read - skipped.') 'Yellow'; continue }
    if (-not $t) { Hk-Say ('  ' + $f.Name + ': the file is empty - skipped.') 'Yellow'; continue }
    $dev = $null; foreach ($d in @($Devices)) { if ($d.serial -and $t.EndsWith([string]$d.serial)) { $dev = $d; break } }
    if (-not $dev) { Hk-Say ('  ' + $f.Name + ': no device here has the serial this file ends with - skipped.') 'Yellow'; continue }
    $k = [string]$dev.serial; if (-not $bySerial.ContainsKey($k)) { $bySerial[$k] = @() }; $bySerial[$k] += $f
  }
  foreach ($k in $bySerial.Keys) {
    $files = @($bySerial[$k]); $f = $files[-1]
    $dev = $null; foreach ($d in @($Devices)) { if ([string]$d.serial -eq $k) { $dev = $d; break } }
    foreach ($o in @($files | Select-Object -First ($files.Count - 1))) { Hk-Say ('  ' + $o.Name + ' (made ' + $o.LastWriteTime.ToString('h:mm tt') + ') is not used: a newer request file for serial ' + $k + ' (' + $f.Name + ', ' + $f.LastWriteTime.ToString('h:mm tt') + ') replaces it. Hikvision''s reply to the older one will not work.') 'Yellow' }
    $cur = Get-HikStateDevice $State $dev.serial
    if ($cur -and $cur.requestFile -eq $f.FullName) { $added += $cur; continue }
    $vw = Get-HikVoidWarning $cur $dev; if ($vw) { Hk-Say $vw $(if ($vw -match 'WARNING') { 'Red' } else { 'Yellow' }) }
    $d2 = Add-HikStateDevice $State $dev $f.FullName $dev.bootTime $f.LastWriteTime
    $added += $d2
  }
  Save-HikState $StatePath $State
  return $added
}

# ---------------- 3. the reply ----------------
# 2.2.0: the relay (HTTPS, by serial) first, then the folders: the reset's replies folder and inbox\hik (the "I got Hik's email" button).
# $script:HkRelayStatus says what the last relay check found, for the screen: state = off | ok | failed; msg; at.
$script:HkRelayStatus = [pscustomobject]@{ state = 'off'; msg = ''; at = '' }
$script:HkRelayNext = [datetime]::MinValue
function Get-HikReplyMessages($Cfg, [string]$ToolkitDir, [string]$ReplyDir, [datetime]$Since, $Pending = @(), [string]$InboxDir = '', [switch]$ForceRelay) {
  $msgs = @()
  $relay = $null; if ($Cfg -and $Cfg.PSObject.Properties['relay']) { $relay = $Cfg.relay }
  if ($relay -and [string]$relay.url -and @($Pending).Count -and ($ForceRelay -or (Get-Date) -ge $script:HkRelayNext)) {
    $every = 60; if ($relay.PSObject.Properties['everySec'] -and [int]$relay.everySec -gt 0) { $every = [int]$relay.everySec }
    $script:HkRelayNext = (Get-Date).AddSeconds($every)
    $key = Get-HikRelayKey $ToolkitDir
    $bad = ''
    foreach ($d in @($Pending)) {
      $r = Get-HikRelayReply $relay $key $d
      if ($r.state -eq 'found') { $msgs += $r.message } elseif ($r.state -eq 'failed') { $bad = $r.msg; break }
    }
    $script:HkRelayStatus = [pscustomobject]@{ state = $(if ($bad) { 'failed' } else { 'ok' }); msg = $bad; at = (Get-Date -Format 's') }
  } elseif (-not $relay -or -not [string]$relay.url) { $script:HkRelayStatus = [pscustomobject]@{ state = 'off'; msg = 'no reply relay set up for this PC'; at = (Get-Date -Format 's') } }
  $msgs += @(Get-HikFolderMessages $ReplyDir $Since)
  if ($InboxDir) { $msgs += @(Get-HikFolderMessages $InboxDir $Since) }
  return $msgs
}
# looks for replies for every 'submitted' device, saves each matched file under replies\reply-<serial>.xml, marks the device 'replied'.
# A file taken from inbox\hik is removed from there once it is saved (it is never used twice).
# 2.2.8: a reply is used only when it arrived AFTER the device's latest export (relay: the mail's receivedAt; .eml: its Date; any other
# file: its file time, which a drop keeps from the downloaded file). An older one answers a request that a later export voided, so the
# device would refuse it: it is listed in "stale" with the reason and never saved or imported. Returns
#   { got; unmatched; stale = [{ serial; name; mail; why }]; skipped = [{ mail; name; why; quiet }] }
# A drop from inbox\hik that is stale, unusable (no / empty / non-xml file) is moved to inbox\hik\not-used\, so it is said once.
function Move-HikDropNotUsed([string]$InboxDir, [string]$Src) {
  if (-not $InboxDir -or -not $Src -or -not $Src.StartsWith($InboxDir) -or -not (Test-Path -LiteralPath $Src)) { return }
  try { $nu = Join-Path $InboxDir 'not-used'; New-Item -ItemType Directory -Force -Path $nu | Out-Null; Move-Item -LiteralPath $Src -Destination (Join-Path $nu (Split-Path -Leaf $Src)) -Force } catch {}
}
function Receive-HikReplies($State, [string]$StatePath, $Cfg, [string]$ToolkitDir, [string]$ReplyDir, [string]$InboxDir = '', [switch]$ForceRelay) {
  $pend = @($State.devices | Where-Object { $_.status -in @('submitted', 'replied') })
  if (-not $pend.Count) { return [pscustomobject]@{ got = @(); unmatched = @(); stale = @(); skipped = @() } }
  # 2.2.8: look back 2 days before the oldest waiting export (a request lives 48 hours), so an older reply is SEEN and named stale
  # instead of being silently out of view (2.2.7 looked back one hour)
  $since = (Get-Date).AddDays(-4); try { $since = ([datetime](@($pend | ForEach-Object { $_.exportedAt } | Sort-Object)[0])).AddDays(-2) } catch {}
  $msgs = @(Get-HikReplyMessages $Cfg $ToolkitDir $ReplyDir $since @($pend | Where-Object { $_.status -eq 'submitted' }) $InboxDir -ForceRelay:$ForceRelay)
  $m = Find-HikReplyMatches $pend $msgs @($State.devices)
  $got = @(); $stale = @()
  New-Item -ItemType Directory -Force -Path $ReplyDir | Out-Null
  $isDrop = { param($s) [bool]($InboxDir -and [string]$s -and ([string]$s).StartsWith($InboxDir)) }
  foreach ($x in $m.matched) {
    $d = $x.device
    # our own request file is not a reply (folder mode could see it); a reply is a different file
    $own = ''; try { $own = [IO.File]::ReadAllText($d.requestFile).Trim() } catch {}
    if ($own -and (Hm-Latin1).GetString($x.bytes).Trim() -eq $own) { continue }
    $dest = Join-Path $ReplyDir ('reply-' + ($d.serial -replace '[^A-Za-z0-9\-]', '_') + '.xml')
    if ($x.src -and $x.src -eq $dest) { continue }   # the file saved by an earlier look
    # 2.2.8: only a reply that arrived after the LATEST export of this device
    $at = ConvertTo-HikLocalTime ([string]$x.date); $exp = ConvertTo-HikLocalTime ([string]$d.exportedAt)
    if ($at -and $exp -and $at -lt $exp) {
      $why = ('it arrived ' + $at.ToString('MMM d h:mm tt') + ', before the latest request file for this device (made ' + $exp.ToString('MMM d h:mm tt') + '). It answers an older request, so the device would refuse it.')
      $stale += [pscustomobject]@{ serial = [string]$d.serial; shortSerial = [string]$d.shortSerial; model = [string]$d.model; ip = [string]$d.ip; name = [string]$x.name; mail = [string]$x.mail; src = [string]$x.src; at = $at.ToString('s'); why = $why }
      if (& $isDrop $x.src) { Move-HikDropNotUsed $InboxDir ([string]$x.src) }
      continue
    }
    if ($d.status -eq 'replied' -and (Test-Path -LiteralPath $dest)) { try { if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)) -eq [Convert]::ToBase64String([byte[]]$x.bytes)) { if (& $isDrop $x.src) { Remove-Item -LiteralPath $x.src -Force -ErrorAction SilentlyContinue }; continue } } catch {} }
    [IO.File]::WriteAllBytes($dest, $x.bytes)
    Set-HikStateField $d 'status' 'replied'; Set-HikStateField $d 'replyFile' $dest; Set-HikStateField $d 'replyFrom' ([string]$x.mail)
    Set-HikStateField $d 'replyAt' $(if ($at) { $at.ToString('s') } else { '' }); Set-HikStateField $d 'replyForExport' $(if ($d.PSObject.Properties['exportId']) { [string]$d.exportId } else { '' })
    $got += $d
    $how = $(if ([string]$x.src -like 'relay:*') { 'the reply mailbox' } elseif (& $isDrop $x.src) { 'the "I got Hik''s email" button' } else { 'the replies folder' })
    Hk-Say ('  Reply for ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ') found in ' + $how + ', matched by ' + $x.how + $(if ($at -and $exp) { '; it came ' + $at.ToString('h:mm tt') + ', after the request file made ' + $exp.ToString('h:mm tt') } else { '' }) + '.') 'Green'
    if (& $isDrop $x.src) { Remove-Item -LiteralPath $x.src -Force -ErrorAction SilentlyContinue }
  }
  foreach ($s in @($m.skipped)) { if (-not $s.quiet -and (& $isDrop $s.src)) { Move-HikDropNotUsed $InboxDir ([string]$s.src) } }
  Save-HikState $StatePath $State
  return [pscustomobject]@{ got = $got; unmatched = @($m.unmatched); stale = @($stale); skipped = @($m.skipped) }
}
# 2.2.8: the plain lines about replies that are NOT used - each said once per run, not on every look (the wait loop looks every few seconds)
$script:HkSaidOnce = @{}
function Show-HikReplyNotes($R) {
  if (-not $R) { return }
  $lines = @()
  foreach ($s in @($R.skipped | Where-Object { $_ -and -not $_.quiet })) {
    $when = ''; $t = ConvertTo-HikLocalTime ([string]$s.date); if ($t) { $when = ', ' + $t.ToString('h:mm tt') }
    $what = $(if ([string]$s.mail) { 'An email from Hikvision ("' + [string]$s.mail + '"' + $when + ')' } else { 'A file from Hikvision' })
    if ([string]$s.why -eq 'it has no attachment') { $lines += , @(($what + ' has no attachment - skipped. If Hikvision sent two emails, the other one has the file.'), 'Yellow') }
    else { $lines += , @(($what + ' skipped: ' + $(if ([string]$s.name) { [string]$s.name + ' - ' } else { '' }) + [string]$s.why + '.'), 'Yellow') }
  }
  foreach ($u in @($R.unmatched | Where-Object { $_ })) { $lines += , @(('A file from Hikvision matches no device here: ' + [string]$u.name + ' - ' + [string]$u.why + '. It is not used.'), 'Yellow') }
  foreach ($s in @($R.stale | Where-Object { $_ })) { $lines += , @(('Not used: the reply ' + [string]$s.name + ' for ' + ([string]$s.model + ' ' + [string]$s.ip).Trim() + ' (serial ' + [string]$s.shortSerial + ') - ' + [string]$s.why + ' Waiting for the reply to the latest request.'), 'Yellow') }
  foreach ($l in $lines) { if ($script:HkSaidOnce.ContainsKey($l[0])) { continue }; $script:HkSaidOnce[$l[0]] = 1; Hk-Say ('  ' + $l[0]) $l[1] }
}
# the devices still waiting for Hikvision, for the "I got Hik's email" button (inbox\hik\waiting.json; no passwords, no codes)
function Save-HikWaitingList([string]$InboxDir, $State, [string]$Site, [string]$ReplyTo = '') {
  if (-not $InboxDir) { return }
  try {
    New-Item -ItemType Directory -Force -Path $InboxDir | Out-Null
    $w = @($State.devices | Where-Object { $_.status -eq 'submitted' } | ForEach-Object { [ordered]@{ serial = [string]$_.serial; shortSerial = [string]$_.shortSerial; model = [string]$_.model; ip = [string]$_.ip; site = $Site; submittedAt = [string]$_.submittedAt } })
    $f = Join-Path $InboxDir 'waiting.json'
    $old = @(); if (Test-Path -LiteralPath $f) { try { $old = @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).devices | Where-Object { $_ -and [string]$_.site -ne $Site }) } catch {} }
    $all = @($old) + @($w)
    ([ordered]@{ updated = (Get-Date -Format 's'); replyTo = $ReplyTo; devices = $all } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $f -Encoding UTF8
  } catch {}
}
# one plain line for the screen about where the reply stands (the waiting message, or why the mailbox could not be checked)
function Format-HikWaitLine($Cfg, [int]$Count, [int]$MinutesLeft) {
  $to = $(if ($Cfg.replyTo) { [string]$Cfg.replyTo } else { 'the email on the form' })
  $st = $script:HkRelayStatus
  $btn = 'Got the email yourself? Press "I got Hik''s email" and drag the attachment in or paste the code.'
  if (-not $Cfg.relay -or -not [string]$Cfg.relay.url -or $st.state -eq 'off') { return [pscustomobject]@{ color = 'Yellow'; text = ('Waiting for Hikvision''s email (' + $Count + ' device(s)). This PC has no reply mailbox set up, so it cannot read the email by itself. When it comes to ' + $to + ', press "I got Hik''s email" and drag the attachment in or paste the code.') } }
  if ($st.state -eq 'failed') { return [pscustomobject]@{ color = 'Yellow'; text = ('Could not check the reply mailbox: ' + $st.msg + '. It keeps trying every minute. ' + $btn) } }
  $at = ''; try { $at = ([datetime]$st.at).ToString('h:mm tt') } catch {}
  return [pscustomobject]@{ color = 'Cyan'; text = ('Waiting for Hikvision''s email to ' + $to + ' (' + $Count + ' device(s)). Checked the mailbox at ' + $at + ': not there yet. Looking every minute for ' + $MinutesLeft + ' more min; it carries on by itself when it comes. ' + $btn) }
}

# ---------------- 4. import + check ----------------
# 2.2.8: what to do after "device refused", in order, with no re-export in between (each export voids the one before)
function Get-HikRefusedSteps($d) {
  $who = ([string]$d.model + ' ' + [string]$d.ip).Trim()
  return @(
    ('  Next, for ' + $who + ' (serial ' + [string]$d.shortSerial + '), in this order and nothing else in between:'),
    '    1. Power-cycle the camera: unplug its power (or its PoE cable) for 10 seconds, plug it back, wait until SADP shows it again.',
    '    2. Export ONE new request file (press Fix this site again, or in SADP: Forgot password > Export). Export only once.',
    '    3. Submit THAT file on Hikvision''s reset page.',
    '    4. Import Hikvision''s reply to that request (the first email after you submitted) - without exporting again first.',
    '    Do not import older files from Downloads: each export voids every earlier reply.'
  )
}
# $VerifyLogin = scriptblock { param($ip, $password) -> $true when the password logs in } (the caller supplies Test-FsLogin).
# $FindIp = scriptblock { param($dev) -> the device's current IP (it may have moved) }.
function Import-HikReplies($State, [string]$StatePath, [string]$NewPassword, [scriptblock]$VerifyLogin, [string]$Only = '', $OnlySerials = $null) {
  $done = @()
  foreach ($d in @($State.devices | Where-Object { $_.status -eq 'replied' -and ($null -eq $OnlySerials -or @($OnlySerials) -contains [string]$_.serial) -and (-not $Only -or $_.serial -like ('*' + $Only + '*') -or $_.ip -eq $Only -or $_.mac -eq $Only) })) {
    Hk-Say ''; Hk-Say ('Importing the unlock file into ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ')') 'Cyan'
    $live = @(Find-HikSadp 3 | Where-Object { $_.mac -eq $d.mac })[0]
    if (-not $live) { Hk-Say '  The device does not answer on the network right now.' 'Yellow'; Set-HikStateField $d 'note' 'not answering'; continue }
    if ($d.bootTime -and $live.bootTime -and $live.bootTime -ne $d.bootTime) { Hk-Say '  This device restarted after the request file was made, so Hikvision''s file no longer fits it. It needs a new request.' 'Red'; Set-HikStateField $d 'status' 'expired'; Set-HikStateField $d 'note' 'restarted since the request'; Save-HikState $StatePath $State; continue }
    if (([datetime]$d.validUntil) -lt (Get-Date)) { Hk-Say '  The file is older than 48 hours - Hikvision''s files stop working then. It needs a new request.' 'Red'; Set-HikStateField $d 'status' 'expired'; Save-HikState $StatePath $State; continue }
    $u = Read-HikUnlock $d.replyFile
    $r = Import-HikUnlock $live $u $NewPassword
    if ($r.ok) {
      Set-HikStateField $d 'status' 'imported'; Set-HikStateField $d 'importedAt' (Get-Date -Format 's'); Save-HikState $StatePath $State
      Start-Sleep -Seconds 3
      $ip = $live.ip; $chk = $false
      # 2.2.3 (Codex #29): wait for the device to be back (SADP, no login), then at most 2 login tries - a wrong password 6 times
      # in a row is how Hikvision locks a device
      $logins = 0; for ($i = 0; $i -lt 8 -and -not $chk -and $logins -lt $script:HkVerifyMaxLogins; $i++) { $now = @(Find-HikSadp 2 | Where-Object { $_.mac -eq $d.mac })[0]; if ($now) { $ip = $now.ip; $logins++; try { $chk = [bool](& $VerifyLogin $ip $NewPassword) } catch {} }; if (-not $chk) { Start-Sleep -Seconds 4 } }
      if ($chk) { Set-HikStateField $d 'status' 'verified'; Set-HikStateField $d 'verifiedAt' (Get-Date -Format 's'); Hk-Say ('  Reset done. The site password logs in on ' + $ip + '.') 'Green'; $done += $d }
      else { Hk-Say ('  The device accepted the file, but the site password does not log in yet on ' + $ip + '. Check it in a minute.') 'Yellow' }
    } elseif ([string]$r.result -and [string]$r.result -notmatch '^(?i)success') {
      # 2.2.8: the device ANSWERED and said no (SADP shows it as "Resetting the password failed. Device refused to process").
      # Almost always: the file does not belong to the device's latest request (an older reply, or a new export made after it was
      # sent). Importing it again, or other files from Downloads, cannot work; a new export now would void the next reply too.
      Set-HikStateField $d 'status' 'refused'; Set-HikStateField $d 'note' ('the device refused the unlock file (it answered "' + [string]$r.result + '")'); Save-HikState $StatePath $State
      Hk-Say ('  The device REFUSED Hikvision''s file (it answered "' + [string]$r.result + '"). This file will not be tried again.') 'Red'
      foreach ($l in @(Get-HikRefusedSteps $d)) { Hk-Say $l 'Yellow' }
    } else {
      Hk-Say ('  The import did not work (' + $r.error + ').') 'Yellow'
      Set-HikStateField $d 'note' ('import: ' + $r.error)
      # last resort, still the official path: SADP's own "Forgot password > Import file" with the file ready
      Hk-Say ('  Finish this one in SADP: tick the device, Forgot password, Import file, pick ' + $d.replyFile + ', type the site password.') 'Yellow'
    }
    Save-HikState $StatePath $State
  }
  return $done
}
function Format-HikStatus($State) {
  $L = @()
  foreach ($d in @($State.devices)) { $L += ('{0,-12} {1,-16} {2,-18} {3}{4}' -f $d.model, $d.ip, $d.serial, $d.status, $(if ($d.note) { ' (' + $d.note + ')' } else { '' })) }
  return $L
}

# ---------------- config ----------------
# 2.2.0: "hikReset": { "relay": { "url": "", "address": "hikreset@wireitct.com", "everySec": 60 }, "waitMinutes": 15, "replyDir": "" }
# No url (or an empty config) = no relay: the flow waits with the "I got Hik's email" button only, and the form keeps config "form.email".
# With a url, Hikvision's form gets relay.address as the email, so the reply lands where the relay reads it.
$script:HkDefaultForm = [ordered]@{ firstName = 'Moshe'; lastName = 'Reichman'; email = 'moshe@wireitct.com'; company = 'WireIt CT LLC'; state = 'Connecticut'; zip = '06710'; businessType = 'Installer' }
# 2.2.1 (review M5): what the official reset still needs, in plain words, said BEFORE the run starts (empty = ready)
function Get-HikReadiness($Cfg, [string]$ToolkitDir = '') {
  $w = @()
  $f = Get-HikFormFor $Cfg
  if (-not $f -or -not [string]$f.email -or -not [string]$f.firstName) { $w += 'Hikvision''s form needs a name and an email (config.json "form").' }
  if (-not [string]$Cfg.relay.url) { $w += 'no reply relay is set up on this PC: when Hikvision''s email comes, press "I got Hik''s email" (the reply goes to ' + $(if ($f) { [string]$f.email } else { 'the form''s email' }) + ').' }
  elseif ($ToolkitDir -and -not (Get-HikRelayKey $ToolkitDir)) { $w += 'this PC has no upload key, so the reply relay cannot be asked (an admin runs "Set upload key.cmd" once); until then use "I got Hik''s email".' }
  try { if (-not (Find-HikBrowser)) { $w += 'Chrome or Edge is not on this PC: Hikvision''s page cannot open here.' } } catch {}
  return @($w)
}
$script:HkVerifyMaxLogins = 2   # 2.2.3 (Codex #29)
function Get-HikConfig($CfgAll, [string]$ToolkitDir = '') {
  $relay = [pscustomobject]@{ url = ''; address = 'hikreset@wireitct.com'; everySec = 60 }
  $wait = 15; $replyDir = ''
  if ($CfgAll -and $CfgAll.PSObject.Properties['hikReset'] -and $CfgAll.hikReset) {
    $h = $CfgAll.hikReset
    if ($h.PSObject.Properties['relay'] -and $h.relay) { foreach ($p in $h.relay.PSObject.Properties) { if ($relay.PSObject.Properties[$p.Name]) { $relay.($p.Name) = $p.Value } } }
    if ($h.PSObject.Properties['waitMinutes'] -and [int]$h.waitMinutes -gt 0) { $wait = [int]$h.waitMinutes }
    if ($h.PSObject.Properties['replyDir']) { $replyDir = [string]$h.replyDir }
    if ($h.PSObject.Properties['sadpLegacyPlainPassword'] -and $h.sadpLegacyPlainPassword -eq $true) { $script:SadpAllowPlainPassword = $true }   # 2.2.3 (Codex #6): Admin's explicit opt-in only
  }
  if ([string]$relay.url -and -not (Test-HikRelayUrl ([string]$relay.url))) { $relay.url = '' }   # http:// or junk = off (never send the key in clear)
  if (-not [string]$relay.address) { $relay.address = 'hikreset@wireitct.com' }
  $form = $null; if ($CfgAll -and $CfgAll.PSObject.Properties['form']) { $form = $CfgAll.form }
  # 2.2.1 (review M5): no "form" in config.json = the Toolkit's own default details (the same ones ToolkitCore uses), not "no reset"
  if (-not $form) { if (Get-Command Get-TkConfig -ErrorAction SilentlyContinue) { try { $form = [pscustomobject](Get-TkConfig $ToolkitDir).form } catch {} }; if (-not $form) { $form = [pscustomobject]$script:HkDefaultForm } }
  $replyTo = $(if ($form -and $form.PSObject.Properties['email']) { [string]$form.email } else { '' })
  if ([string]$relay.url) { $replyTo = [string]$relay.address }
  return [pscustomobject]@{ form = $form; relay = $relay; waitMinutes = $wait; replyDir = $replyDir; replyTo = $replyTo }
}
# the form as it goes to Hikvision: the reply address is the relay's when the relay is on
function Get-HikFormFor($Cfg) {
  if (-not $Cfg.form) { return $null }
  $f = [ordered]@{}
  if ($Cfg.form -is [Collections.IDictionary]) { foreach ($k in @($Cfg.form.Keys)) { $f[$k] = $Cfg.form[$k] } } else { foreach ($p in $Cfg.form.PSObject.Properties) { $f[$p.Name] = $p.Value } }
  if ($Cfg.replyTo) { $f['email'] = [string]$Cfg.replyTo }
  return [pscustomobject]$f
}

# ---------------- the whole thing for a list of devices ----------------
# $Targets: objects with .mac (the devices whose password is unknown). Returns { fixed = @(macs); pending = @({ mac; reason }) }.
function Invoke-HikResetStage {
  # 2.2.0: $ToolkitDir (the relay key), $InboxDir (the "I got Hik's email" drops), $Site (named in inbox\hik\waiting.json)
  param($Targets, [string]$SitePassword, [string]$StateDir, $Config, [string]$ToolkitDir = '', [scriptblock]$VerifyLogin, [int]$WaitMinutes = 15, [int]$SubmitTimeoutSec = 900, [string]$InboxDir = '', [string]$Site = '', [int]$InboxEverySec = 5)
  $statePath = Join-Path $StateDir 'state.json'; $reqDir = Join-Path $StateDir 'requests'
  $repDir = $(if ($Config.replyDir) { $Config.replyDir } else { Join-Path $StateDir 'replies' })
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $state = Read-HikState $statePath
  $want = @{}; foreach ($t in @($Targets)) { $m = ConvertTo-SadpMac ([string]$t.mac); if ($m) { $want[$m] = $t } }
  Hk-Say 'Finding the Hikvision devices (any IP range)...'
  $devs = @(Find-HikSadp 4 | Where-Object { $want.ContainsKey($_.mac) })
  $fixed = @(); $pending = @()
  foreach ($m in $want.Keys) { if (-not @($devs | Where-Object { $_.mac -eq $m }).Count) { $pending += [pscustomobject]@{ mac = $m; reason = 'not seen on the network (check power and cable)' } } }
  $forMine = { param($st) @($st.devices | Where-Object { $want.ContainsKey((ConvertTo-SadpMac ([string]$_.mac))) }) }
  # 2.2.1: a device whose unlock file was imported in an earlier run that stopped before the check: check its login now (once)
  # 2.2.2 (Codex, reset resume): this check runs BEFORE any new export. 2.2.1 exported first, which reset an "imported" device to
  # "exported", so the check never saw it (and a fresh request cancelled the reset that had worked).
  foreach ($d in @(& $forMine $state | Where-Object { $_.status -eq 'imported' })) {
    $okv = $false; try { $okv = [bool](& $VerifyLogin ([string]$d.ip) $SitePassword) } catch {}
    if ($okv) { Set-HikStateField $d 'status' 'verified'; Set-HikStateField $d 'verifiedAt' (Get-Date -Format 's'); Save-HikState $statePath $state; $fixed += (ConvertTo-SadpMac ([string]$d.mac)); Hk-Say ('  ' + $d.model + ' ' + $d.ip + ': the earlier reset worked - the site password logs in.') 'Green' }
  }
  # 2.2.3 (Codex #57): a reset verified in an EARLIER run counts only if the site password still logs in now (one try, at the address
  # the device has now). A factory reset or password change since then = it is reset again.
  foreach ($d in @(& $forMine $state | Where-Object { $_.status -eq 'verified' })) {
    $mv = ConvertTo-SadpMac ([string]$d.mac); if ($fixed -contains $mv) { continue }
    $live = @($devs | Where-Object { $_.mac -eq $mv })[0]; $ipNow = $(if ($live) { [string]$live.ip } else { [string]$d.ip })
    $okv = $false; if ($live) { try { $okv = [bool](& $VerifyLogin $ipNow $SitePassword) } catch {} }
    if ($okv) { $fixed += $mv }
    elseif ($live) { Set-HikStateField $d 'status' 'stale'; Save-HikState $statePath $state; Hk-Say ('  ' + $d.model + ' ' + $ipNow + ': was reset before, but the site password no longer logs in - it is reset again.') 'Yellow' }
  }
  # a device that is already done is never asked for a new request file
  $todo = @($devs | Where-Object { $_.activated -and $fixed -notcontains (ConvertTo-SadpMac ([string]$_.mac)) })
  # an old state (reply still waiting from an earlier run) is picked up as it is
  Hk-Say ('Asking each of the ' + $todo.Count + ' device(s) for its reset request file (same as SADP "Forgot password > Export file")...')
  [void](Export-HikRequests $todo $reqDir $state $statePath)
  $form = Get-HikFormFor $Config
  if (-not $form) { return [pscustomobject]@{ fixed = @($fixed); pending = @($pending) + @($todo | ForEach-Object { [pscustomobject]@{ mac = $_.mac; reason = 'config.json has no "form" (name, email, company)' } }) } }
  $mine = @(& $forMine $state | ForEach-Object { [string]$_.serial })
  [void](Submit-HikRequests $state $statePath $form $SubmitTimeoutSec $mine)
  Save-HikWaitingList $InboxDir $state $Site ([string]$Config.replyTo)
  $end = (Get-Date).AddMinutes($WaitMinutes); $lastLine = ''; $lastSaid = [datetime]::MinValue; $first = $true
  do {
    $r = Receive-HikReplies $state $statePath $Config $ToolkitDir $repDir $InboxDir -ForceRelay:$first
    $first = $false
    Show-HikReplyNotes $r   # 2.2.8: skipped / stale / unmatched files, each with its reason, said once
    $waiting = @(& $forMine $state | Where-Object { $_.status -eq 'submitted' })
    if ($r.got.Count) { Save-HikWaitingList $InboxDir $state $Site ([string]$Config.replyTo) }
    $left = [math]::Max(0, [int][math]::Ceiling(($end - (Get-Date)).TotalMinutes))
    $line = Format-HikWaitLine $Config $waiting.Count $left
    if ($script:HkStatus) { try { & $script:HkStatus ([pscustomobject]@{ waiting = @($waiting | ForEach-Object { [pscustomobject]@{ serial = $_.serial; shortSerial = $_.shortSerial; model = $_.model; ip = $_.ip } }); relay = $script:HkRelayStatus; replyTo = [string]$Config.replyTo; minutesLeft = $left; line = $line.text }) } catch {} }
    if (-not $waiting.Count -or (Get-Date) -ge $end) { break }
    # say it when it changes (or every 5 minutes), not every few seconds
    $key = $script:HkRelayStatus.state + '|' + $script:HkRelayStatus.msg + '|' + $waiting.Count
    if ($key -ne $lastLine -or ((Get-Date) - $lastSaid).TotalMinutes -ge 5) { Hk-Say ('  ' + $line.text) $line.color; $lastLine = $key; $lastSaid = Get-Date }
    Start-Sleep -Seconds ([math]::Max(1, $InboxEverySec))
  } while ($true)
  $ready = @(& $forMine $state | Where-Object { $_.status -eq 'replied' })
  if ($ready.Count) { $done = @(Import-HikReplies $state $statePath $SitePassword $VerifyLogin '' $mine); foreach ($d in $done) { $fixed += (ConvertTo-SadpMac ([string]$d.mac)) } }
  Save-HikWaitingList $InboxDir $state $Site ([string]$Config.replyTo)
  if ($script:HkStatus) { try { & $script:HkStatus ([pscustomobject]@{ waiting = @(); relay = $script:HkRelayStatus; replyTo = [string]$Config.replyTo; minutesLeft = 0; line = ''; done = $true }) } catch {} }
  foreach ($d in @(& $forMine $state)) {
    if ($fixed -contains (ConvertTo-SadpMac ([string]$d.mac))) { continue }
    $why = switch ($d.status) { 'submitted' { 'sent to Hikvision, waiting for the unlock email (it can take a few hours). When it comes: press "I got Hik''s email" (or, with the reply mailbox set up, just press Fix this site again). The device must NOT restart meanwhile.' } 'exported' { 'request file made, not sent to Hikvision yet' } 'replied' { 'unlock file arrived but the import did not work' + $(if ($d.note) { ' (' + $d.note + ')' } else { '' }) } 'expired' { 'the request is no longer valid (' + $d.note + '): it needs a new one' } 'refused' { 'the device refused Hikvision''s file. Power-cycle it, then press Fix this site again: it makes ONE new request; submit it and import only the reply to it (no export in between)' } default { [string]$d.status } }
    $pending += [pscustomobject]@{ mac = $d.mac; reason = $why }
  }
  return [pscustomobject]@{ fixed = @($fixed); pending = @($pending) }
}
